defmodule Mist.Nostr.SubManager do
  @moduledoc """
  Single owner of all relay subscriptions.

  Three kinds of subscriptions live here:

    * **Named (ad-hoc) subscriptions** — UI/profile driven filters
      (`:notes_feed`, profile lookups, follow-list fetches). Managed via
      `subscribe/2`, `subscribe_with_name/3` and `cancel_named_subscription/1`.

    * **Self-meta subscription** — one persistent subscription for the
      identity's own kind 0 (profile), kind 3 (follow list) and kind 10002
      (relay list) events, opened on the bootstrap relay (or a relay hint
      given at identity switch). This replaces the old one-shot bootstrap
      fetch: live updates flow continuously, and a dead bootstrap relay is
      retried by the reconcile tick instead of leaving the feed empty.

    * **Feed subscriptions** — the follow-graph feed. A reconciliation loop
      computes the *desired* state from the DB (my follows → their NIP-65
      write relays, falling back to a set of well-known relays for follows
      with no known relays) and diffs it against the *actual* open
      subscriptions, opening and closing subscriptions as needed.

  This GenServer is the single event ingress for all subscriptions: every
  relay event is forwarded to `Mist.Nostr.EventHandler` in a supervised task.

  Reconciliation is triggered by: startup, `identity_switched/2`,
  `profile:new_follow`, `profile:follow_list_updated`,
  `profile:user_relays_updated`, and a periodic tick which also re-heals
  relays whose connections dropped (NostrEx does not reconnect on its own).
  """

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Mist.{Notes, Profile, Relay, Repo}
  alias Mist.Nostr.{EventHandler, Identity}

  @pubsub Mist.PubSub

  @feed_kinds [1, 6, 7, 9735]
  @meta_kinds [0, 3, 10002]
  @profile_kinds [0]
  @chunk_size 200
  @reconcile_debounce 1_000
  @tick_interval 5 * 60 * 1_000
  @backfill_interval 10 * 60 * 1_000
  @backfill_initial_delay 3_000
  # Profile backfill subs are one-shot kind-0 fetches: relays hold REQs
  # open until CLOSE (and cap concurrent REQs), so they are closed on this
  # TTL instead of lingering for the lifetime of the session.
  @profile_sub_ttl 30_000
  @permanent_blacklist_threshold 3
  @dead_relay_expiry_seconds 7 * 24 * 3600
  @identity_retry_interval 200
  @identity_max_retries 50

  @default_bootstrap_relay "wss://purplepag.es"

  @default_fallback_relays [
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]

  defstruct named: %{},
            feed: %{},
            identity: nil,
            meta_sub: nil,
            meta_relay_hint: nil,
            identity_retries: 0,
            reconcile_timer: nil,
            profiles_fetched: MapSet.new(),
            profile_subs: MapSet.new(),
            relay_health: %{}

  # feed: %{relay_url => %{sub_id => MapSet.t(pubkey)}}
  # named: %{name => sub_id}
  # meta_sub: sub_id | nil

  ## Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc "Open an anonymous subscription. Events are processed by EventHandler."
  def subscribe(filters, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe, filters, opts})
  end

  @doc "Open a subscription under a name, replacing any previous one with the same name."
  def subscribe_with_name(name, filters, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_named, name, filters, opts})
  end

  def cancel_named_subscription(name) do
    GenServer.cast(__MODULE__, {:cancel_named, name})
  end

  def cancel_all_subscriptions do
    GenServer.cast(__MODULE__, :cancel_all)
  end

  @doc """
  Point SubManager at a new identity: closes the previous identity's
  subscriptions, opens a self-meta sub for the new one (using `relay_hint`
  for the meta sub when given), and reconciles feed subscriptions.
  """
  def identity_switched(pubkey, relay_hint \\ nil) when is_binary(pubkey) do
    GenServer.cast(__MODULE__, {:identity_switched, pubkey, relay_hint})
  end

  @doc "Fetch kind 0 (profile) and kind 10002 (relay list) events for the given pubkeys."
  # No `since` filter on purpose: kind-0/10002 events are not persisted to the
  # events table, so `Notes.since_for_filter/1` would always fall back to the
  # 24h window and miss virtually all historical profile events. These subs
  # are one-shot and limit-capped, so fetching all-time is correct and cheap.
  def subscribe_profiles(pubkeys, opts \\ []) when is_list(pubkeys) do
    kinds = @profile_kinds
    limit = Notes.default_limit()

    case NostrEx.create_sub(authors: pubkeys, kinds: kinds, limit: limit) do
      {:ok, sub} -> subscribe(sub, opts)
      {:error, reason} -> Logger.error("SubManager: failed to create profile subscription: #{inspect(reason)}")
    end
  end

  @doc "Fetch the kind 3 follow list for the given pubkey."
  def subscribe_follows(pubkey) when is_binary(pubkey) do
    kinds = [3]
    since = Notes.since_for_filter(kinds: kinds, authors: [pubkey])
    limit = Notes.default_limit()

    case NostrEx.create_sub(authors: [pubkey], kinds: kinds, since: since, limit: limit) do
      {:ok, sub} -> subscribe(sub, [])
      {:error, reason} -> Logger.error("SubManager: failed to create follows subscription: #{inspect(reason)}")
    end
  end

  ## Server callbacks

  @impl GenServer
  def init(state) do
    Phoenix.PubSub.subscribe(@pubsub, "profile:new_follow")
    Phoenix.PubSub.subscribe(@pubsub, "profile:follow_list_updated")
    Phoenix.PubSub.subscribe(@pubsub, "profile:user_relays_updated")

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    Process.send_after(self(), :reconcile_tick, @tick_interval)
    state = load_persistent_blacklist(state)
    {:noreply, resolve_identity(state)}
  end

  defp load_persistent_blacklist(state) do
    rows =
      from(r in Mist.Relay.Info, where: not is_nil(r.blacklisted_at))
      |> Repo.all()

    Enum.reduce(rows, state, fn relay, acc ->
      host = Relay.relay_name(relay.url)
      reason = if relay.blacklist_reason == "auth", do: :auth, else: :connection_failed
      blacklisted_at = DateTime.to_unix(relay.blacklisted_at, :second)

      entry = %{
        failures: relay.failure_count,
        blackout_until: 0,
        permanent: true,
        reason: reason,
        blacklisted_at: blacklisted_at
      }

      %{acc | relay_health: Map.put(acc.relay_health, host, entry)}
    end)
  end

  # The Signer sets the identity in its own handle_continue, which is not
  # ordered against ours — retry until it appears (same retry pattern the old Initializer used).
  defp resolve_identity(%{identity_retries: retries} = state) do
    case Identity.current_pubkey() do
      nil when retries < @identity_max_retries ->
        Process.send_after(self(), :retry_identity, @identity_retry_interval)
        %{state | identity_retries: retries + 1}

      nil ->
        Logger.warning("SubManager: no identity after #{retries} retries, feed subscriptions idle until identity is set")
        state

      pubkey ->
        Process.send_after(self(), :backfill_tick, @backfill_initial_delay)
        reconcile(%{state | identity: pubkey})
    end
  end

  # ── Named / ad-hoc subscriptions ──────────────────────────

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    with {:ok, {sub, send_opts}} <- prepare_subscription(filters, opts),
         :ok <- NostrEx.listen(sub),
         {:ok, _sub_id, _failures} <- NostrEx.send_sub(sub, send_opts) do
      Logger.debug("SubManager: created subscription #{sub.id}")
    else
      {:error, :no_relays, _relays} ->
        Logger.error("SubManager: no relays connected for subscription")
      {:error, reason} ->
        Logger.error("SubManager: failed to create subscription: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:subscribe_named, name, filters, opts}, state) do
    state = cancel_named_sub(state, name)

    with {:ok, {sub, send_opts}} <- prepare_subscription(filters, opts),
         :ok <- NostrEx.listen(sub),
         {:ok, _sub_id, _failures} <- NostrEx.send_sub(sub, send_opts) do
      Logger.debug("SubManager: created named subscription #{name} -> #{sub.id}")
      {:noreply, %{state | named: Map.put(state.named, name, sub.id)}}
    else
      {:error, :no_relays, _relays} ->
        Logger.error("SubManager: no relays connected for named subscription #{name}")
        {:noreply, state}
      {:error, reason} ->
        Logger.error("SubManager: failed to create named subscription #{name}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:cancel_named, name}, state) do
    {:noreply, cancel_named_sub(state, name)}
  end

  def handle_cast(:cancel_all, state) do
    Enum.each(state.named, fn {_name, sub_id} ->
      NostrEx.close_sub(sub_id)
      Logger.debug("SubManager: cancelled subscription #{sub_id}")
    end)

    {:noreply, %{state | named: %{}}}
  end

  def handle_cast({:identity_switched, pubkey, relay_hint}, state) do
    Logger.info("SubManager: identity switched, resetting subscriptions")

    state =
      state
      |> close_all_feed_subs()
      |> close_meta_sub()
      |> close_profile_subs()
      |> Map.merge(%{identity: pubkey, meta_relay_hint: relay_hint})

    {:noreply, schedule_reconcile(state)}
  end

  # ── Reconciliation triggers ───────────────────────────────

  @impl GenServer
  def handle_info({:new_follow, _pubkey}, state) do
    {:noreply, schedule_reconcile(state)}
  end

  def handle_info({:follow_list_updated, follower_pubkey}, state) do
    if follower_pubkey == state.identity do
      {:noreply, schedule_reconcile(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:user_relays_updated, _pubkey}, state) do
    {:noreply, schedule_reconcile(state)}
  end

  def handle_info(:reconcile_now, state) do
    {:noreply, %{reconcile(state) | reconcile_timer: nil}}
  end

  def handle_info(:reconcile_tick, state) do
    Process.send_after(self(), :reconcile_tick, @tick_interval)
    {:noreply, state |> prune_expired_blacklists() |> heal_dead_relays() |> reconcile()}
  end

  def handle_info(:retry_identity, state) do
    {:noreply, resolve_identity(state)}
  end

  # Profile backfill runs on its own slow timer, decoupled from the reconcile
  # cycle so it never amplifies reconcile churn. Fetches kind-0 for follows
  # not yet fetched this session; no-ops once everyone's covered.
  def handle_info(:backfill_tick, state) do
    Process.send_after(self(), :backfill_tick, @backfill_interval)

    if state.identity do
      desired = desired_feeds(state.identity)
      {:noreply, backfill_profiles(state, desired)}
    else
      {:noreply, state}
    end
  end

  # TTL close for profile backfill subs: keeps concurrent REQs bounded on
  # the relays. Events already in flight when the CLOSE lands are still
  # dispatched and processed.
  def handle_info({:close_profile_sub, sub_id}, state) do
    if MapSet.member?(state.profile_subs, sub_id) do
      Logger.debug("SubManager: closing profile backfill sub #{String.slice(sub_id, 0, 8)}")
      NostrEx.close_sub(sub_id)
      # Drop this process's listener registration for the sub topic too —
      # SubManager is long-lived and would otherwise accumulate one registry
      # entry per backfill sub forever.
      Registry.unregister(NostrEx.PubSub, sub_id)
      {:noreply, %{state | profile_subs: MapSet.delete(state.profile_subs, sub_id)}}
    else
      {:noreply, state}
    end
  end

  # ── Event ingress ─────────────────────────────────────────

  def handle_info({:event, _sub_id, event}, state) do
    Task.Supervisor.start_child(Mist.TaskSupervisor, fn ->
      EventHandler.process_event(event)
    end)

    {:noreply, state}
  end

  def handle_info({:eose, sub_id, relay}, state) do
    Logger.debug("SubManager: EOSE for #{String.slice(sub_id, 0, 8)} from #{relay}")
    {:noreply, state}
  end

  # Relay-initiated CLOSE with a reason (NIP-01 CLOSED). If the reason
  # indicates auth-required or rate-limiting — which we can't fulfill —
  # permanently blacklist the relay so we stop thrashing. Its follows are
  # rerouted to fallbacks on the next reconcile.
  def handle_info({:close, sub_id, relay_host, message}, state) do
    Logger.info("SubManager: #{relay_host} closed sub #{String.slice(sub_id, 0, 8)}: #{message}")

    msg = String.downcase(message)
    state =
      if String.contains?(msg, "auth") or String.contains?(msg, "rate") do
        permanent_blacklist(state, relay_host)
      else
        state
      end

    {:noreply, evict_sub(state, relay_host, sub_id)}
  end

  # Relay-initiated CLOSE without a reason (older relays). Evict and retry.
  def handle_info({:close, sub_id, relay_host}, state) do
    Logger.info("SubManager: #{relay_host} closed sub #{String.slice(sub_id, 0, 8)}")
    {:noreply, evict_sub(state, relay_host, sub_id)}
  end

  # NOTICE from a relay (dispatched by nostr_ex to all sub listeners on that
  # relay). Auth-required notices that aren't paired with a CLOSED get caught
  # here — instant permanent blacklist so we stop reconnecting to relays
  # that demand NIP-42 auth we can't fulfill.
  def handle_info({:notice, _sub_id, relay_host, message}, state) do
    msg = String.downcase(message)

    state =
      if String.contains?(msg, "auth") do
        permanent_blacklist(state, relay_host)
      else
        Logger.info("SubManager: notice from #{relay_host}: #{message}")
        state
      end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("SubManager: unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Feed reconciliation

  defp schedule_reconcile(%{reconcile_timer: nil} = state) do
    timer = Process.send_after(self(), :reconcile_now, @reconcile_debounce)
    %{state | reconcile_timer: timer}
  end

  defp schedule_reconcile(state), do: state

  defp reconcile(%{identity: nil} = state), do: state

  defp reconcile(state) do
    state = ensure_meta_sub(state)
    raw_desired = desired_feeds(state.identity)

    # Reroute follows whose advertised write relays are in a health blackout
    # onto the fallback set, so dead relays don't silently drop their follows.
    desired = reroute_blacklisted(state, raw_desired)

    state
    |> close_feed_subs_for_undesired_relays(desired)
    |> open_feed_subs_for_missing(desired)
  end

  ## Relay health & follow fallback

  # Relays in a health blackout (repeated connect failures) are removed from
  # the desired feed map and their follows redistributed across usable
  # fallback relays, so a follow whose write relays are all dead still gets a
  # feed subscription. If every fallback is also blacklisted, the follows are
  # dropped this round and retried on the next reconcile.
  @doc false
  def reroute_blacklisted(state, desired) do
    now = System.os_time(:second)
    fallbacks = fallback_relays()
    usable_fallbacks = Enum.reject(fallbacks, &blacklisted?(state, &1, now))

    {kept, rerouted} =
      Enum.reduce(desired, {%{}, MapSet.new()}, fn {relay, pubkeys}, {kept, acc} ->
        if blacklisted?(state, relay, now) do
          {kept, MapSet.union(acc, pubkeys)}
        else
          {Map.put(kept, relay, pubkeys), acc}
        end
      end)

    if MapSet.size(rerouted) == 0 or usable_fallbacks == [] do
      kept
    else
      Enum.reduce(usable_fallbacks, kept, fn fb, acc ->
        Map.update(acc, fb, rerouted, &MapSet.union(&1, rerouted))
      end)
    end
  end

  defp prune_expired_blacklists(state) do
    now = System.os_time(:second)

    {keep, clear} =
      Enum.split_with(state.relay_health, fn {_host, entry} ->
        case entry do
          %{permanent: true, reason: :connection_failed, blacklisted_at: ts}
            when now - ts >= @dead_relay_expiry_seconds ->
            false
          _ ->
            true
        end
      end)

    for {host, _entry} <- clear do
      Logger.info("SubManager: clearing expired blacklist for #{host} (7-day TTL)")
      case Repo.get_by(Mist.Relay.Info, name: host) do
        nil -> :ok
        relay ->
          Relay.Info.changeset(relay, %{
            failure_count: 0,
            blacklisted_at: nil,
            blacklist_reason: nil
          })
          |> Repo.update()
      end
    end

    %{state | relay_health: Map.new(keep)}
  end

  defp blacklisted?(state, url, now) do
    host = Relay.relay_name(url)
    case state.relay_health[host] do
      %{permanent: true} -> true
      %{blackout_until: until} when until > now -> true
      _ -> false
    end
  end

  # Record a connect failure with exponential backoff (30s, 60s, 120s, ...
  # capped at 30min). After @permanent_blacklist_threshold failures the relay
  # is permanently blacklisted — TLS errors, non-existent domains, etc. won't
  # fix themselves, so stop retrying.
  @doc false
  def record_relay_failures(state, urls) do
    now = System.os_time(:second)

    Enum.reduce(urls, state, fn url, state ->
      host = Relay.relay_name(url)
      prev = state.relay_health[host] || %{failures: 0}
      failures = prev.failures + 1

      permanent = failures >= @permanent_blacklist_threshold
      backoff = case failures do
        1 -> 300
        2 -> 900
        _ -> 0
      end

      entry = %{failures: failures, blackout_until: now + backoff}
      entry = if permanent, do: Map.merge(entry, %{permanent: true, reason: :connection_failed, blacklisted_at: now}), else: entry

      if permanent and not match?(%{permanent: true}, prev) do
        Logger.info("SubManager: permanently blacklisted #{host} (#{failures} connect failures)")
        persist_blacklist(url, failures, "connection_failed")
        # Kill the socket's reconnect loop, if one is still running.
        NostrEx.disconnect(host)
      end

      %{state | relay_health: Map.put(state.relay_health, host, entry)}
    end)
  end

  # Permanently blacklist a relay by host (used for auth-required / rate-
  # limited relays that we can't fulfill). The relay's follows are rerouted
  # to fallbacks on the next reconcile via reroute_blacklisted.
  @doc false
  def permanent_blacklist(state, host) do
    host = if String.starts_with?(host, "wss://") or String.starts_with?(host, "ws://"),
      do: Relay.relay_name(host), else: host

    case state.relay_health[host] do
      %{permanent: true} ->
        state

      _ ->
        Logger.info("SubManager: permanently blacklisted #{host} (auth required / rate limited)")
        persist_blacklist(host, 99, "auth")
        # Kill the socket's reconnect loop, if one is still running.
        NostrEx.disconnect(host)
        now = System.os_time(:second)
        %{state | relay_health: Map.put(state.relay_health, host, %{failures: 99, blackout_until: 0, permanent: true, reason: :auth, blacklisted_at: now})}
    end
  end

  # A successful connect clears any prior failure history for the relay.
  @doc false
  def clear_relay_failures(state, urls) do
    hosts = Enum.map(urls, &Relay.relay_name(&1))

    for url <- urls do
      case Relay.get_relay_by_url(url) do
        {:ok, relay} ->
          Relay.Info.changeset(relay, %{
            failure_count: 0,
            blacklisted_at: nil,
            blacklist_reason: nil
          })
          |> Repo.update()
        {:error, _} -> :ok
      end
    end

    %{state | relay_health: Map.drop(state.relay_health, hosts)}
  end

  defp persist_blacklist(url_or_host, failure_count, reason) do
    url = if String.starts_with?(url_or_host, "wss://") or String.starts_with?(url_or_host, "ws://"),
      do: url_or_host, else: nil

    relay =
      cond do
        is_binary(url) ->
          case Relay.get_relay_by_url(url) do
            {:ok, r} -> r
            {:error, _} -> nil
          end
        true ->
          host = String.downcase(url_or_host)
          Repo.get_by(Mist.Relay.Info, name: host)
      end

    if relay do
      Relay.Info.changeset(relay, %{
        failure_count: failure_count,
        blacklisted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        blacklist_reason: reason
      })
      |> Repo.update()
    end
  end

  ## Profile backfill

  # Profiles (kind 0) for all follows — and the second hop of the follow
  # graph, so second-hop authors get names/avatars — are fetched once per
  # session on a slow background timer (every 10 min, first pass 3s after
  # identity is set). Decoupled from reconcile so it never amplifies
  # reconcile churn; no-ops once everyone is fetched.
  @doc false
  def backfill_profiles(state, desired) do
    follows = desired |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    secondary =
      if state.identity do
        state.identity
        |> Profile.second_hop_pubkeys(Application.get_env(:mist, :second_hop_cap, 300))
        |> MapSet.new()
      else
        MapSet.new()
      end

    all = MapSet.union(follows, secondary)
    new = MapSet.difference(all, state.profiles_fetched)

    if MapSet.size(new) == 0 do
      state
    else
      # purplepag.es is a kind-0 directory; fallbacks cover the rest.
      # Skip relays that are permanently blacklisted (auth-required, dead).
      now = System.os_time(:second)
      relays =
        Enum.uniq([bootstrap_relay() | fallback_relays()])
        |> Enum.reject(&blacklisted?(state, &1, now))

      {fetched, sub_ids} =
        new
        |> MapSet.to_list()
        |> Enum.chunk_every(@chunk_size)
        |> Enum.reduce({[], MapSet.new()}, fn chunk, {pubkeys, subs} ->
          case open_profile_sub(chunk, relays) do
            {:ok, sub_id} ->
              Process.send_after(self(), {:close_profile_sub, sub_id}, @profile_sub_ttl)
              {pubkeys ++ chunk, MapSet.put(subs, sub_id)}

            :error ->
              {pubkeys, subs}
          end
        end)

      %{
        state
        | profiles_fetched: Enum.reduce(fetched, state.profiles_fetched, &MapSet.put(&2, &1)),
          profile_subs: MapSet.union(state.profile_subs, sub_ids)
      }
    end
  end

  # See subscribe_profiles/2 for why there is no `since` here.
  defp open_profile_sub(pubkeys, relays) do
    limit = Notes.default_limit()

    with {:ok, sub} <- NostrEx.create_sub(authors: pubkeys, kinds: @profile_kinds, limit: limit),
         :ok <- NostrEx.listen(sub),
         {:ok, sub_id, _failures} <- NostrEx.send_sub(sub, send_via: relays) do
      Logger.info("SubManager: profile backfill sub for #{length(pubkeys)} pubkey(s)")
      {:ok, sub_id}
    else
      {:error, :no_relays, _relays} ->
        Logger.error("SubManager: no relays connected for profile backfill")
        :error

      {:error, reason, _failures} ->
        Logger.error("SubManager: failed to open profile backfill sub: #{inspect(reason)}")
        :error

      {:error, reason} ->
        Logger.error("SubManager: failed to open profile backfill sub: #{inspect(reason)}")
        :error
    end
  end

  ## Self-meta subscription

  # One persistent sub for the identity's own profile/follow-list/relay-list
  # events. Lives next to the feed subs; its events drive reconciliation via
  # the EventHandler -> PubSub triggers.
  defp ensure_meta_sub(%{meta_sub: sub_id} = state) when is_binary(sub_id), do: state

  defp ensure_meta_sub(state) do
    relay = state.meta_relay_hint || bootstrap_relay()

    with {:ok, connected, _failed} <- Relay.maybe_connect_relays([relay]),
         true <- relay in connected,
         {:ok, sub} <- NostrEx.create_sub(authors: [state.identity], kinds: @meta_kinds),
         :ok <- NostrEx.listen(sub),
         {:ok, sub_id, _failures} <- NostrEx.send_sub(sub, send_via: [relay]) do
      Logger.info("SubManager: self-meta sub on #{relay}")
      %{state | meta_sub: sub_id}
    else
      _ ->
        Logger.warning("SubManager: could not open self-meta sub on #{relay}, will retry on next reconcile")
        state
    end
  end

  defp close_meta_sub(%{meta_sub: nil} = state), do: state

  defp close_meta_sub(%{meta_sub: sub_id} = state) do
    NostrEx.close_sub(sub_id)
    %{state | meta_sub: nil}
  end

  defp close_profile_subs(%{profile_subs: subs} = state) do
    Enum.each(subs, fn sub_id ->
      NostrEx.close_sub(sub_id)
      Registry.unregister(NostrEx.PubSub, sub_id)
    end)

    %{state | profile_subs: MapSet.new()}
  end

  defp bootstrap_relay do
    Application.get_env(:mist, :bootstrap_relay, @default_bootstrap_relay)
  end

  @doc false
  def desired_feeds(identity) when is_binary(identity) do
    follows = follow_profiles(identity)

    by_relay =
      follows
      |> Profile.get_write_relays_by_relay()
      |> Map.filter(fn {relay, _} -> valid_relay_url?(relay) end)

    covered = by_relay |> Map.values() |> List.flatten() |> MapSet.new()

    uncovered =
      follows
      |> Enum.map(& &1.pubkey)
      |> Enum.reject(&MapSet.member?(covered, &1))

    desired = Map.new(by_relay, fn {relay, pubkeys} -> {relay, MapSet.new(pubkeys)} end)

    desired = Enum.reduce(uncovered, desired, fn pubkey, acc ->
      Enum.reduce(fallback_relays(), acc, fn relay, acc2 ->
        Map.update(acc2, relay, MapSet.new([pubkey]), &MapSet.put(&1, pubkey))
      end)
    end)

    cap_feed_relays(desired)
  end

  # Hard cap on the number of feed relays. Sorts by coverage (number of
  # pubkeys served) descending, keeps the top N, and redistributes the
  # cut-off relays' follows across fallback relays. Only active in dev.
  defp cap_feed_relays(desired) do
    cap = Application.get_env(:mist, :max_feed_relays, 0)

    if cap > 0 and map_size(desired) > cap do
      fallbacks = fallback_relays()

      {kept, cut} =
        desired
        |> Enum.sort_by(fn {_relay, pubkeys} -> MapSet.size(pubkeys) end, :desc)
        |> Enum.split(cap)

      kept = Map.new(kept)

      Enum.reduce(cut, kept, fn {_relay, pubkeys}, acc ->
        Enum.reduce(pubkeys, acc, fn pubkey, acc2 ->
          Enum.reduce(fallbacks, acc2, fn relay, acc3 ->
            Map.update(acc3, relay, MapSet.new([pubkey]), &MapSet.put(&1, pubkey))
          end)
        end)
      end)
    else
      desired
    end
  end

  defp close_feed_subs_for_undesired_relays(state, desired) do
    feed =
      Map.new(state.feed, fn {relay, subs} ->
        if Map.has_key?(desired, relay) do
          {relay, subs}
        else
          Enum.each(Map.keys(subs), &NostrEx.close_sub/1)
          {relay, :closed}
        end
      end)
      |> Map.reject(fn {_relay, subs} -> subs == :closed end)

    %{state | feed: feed}
  end

  defp open_feed_subs_for_missing(state, desired) do
    # Wanted pubkeys per relay that aren't already covered by an existing sub.
    missing_by_relay =
      Map.new(desired, fn {relay, wanted} ->
        covered =
          state.feed
          |> Map.get(relay, %{})
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        {relay, MapSet.difference(wanted, covered)}
      end)
      |> Map.reject(fn {_relay, missing} -> MapSet.size(missing) == 0 end)

    if map_size(missing_by_relay) == 0 do
      state
    else
      {:ok, connected, failed} = Relay.maybe_connect_relays(Map.keys(missing_by_relay))
      state = record_relay_failures(state, failed)
      state = clear_relay_failures(state, connected)

      # Open subs only on relays that actually connected. Follows on relays
      # that failed this round stay in `desired`; the failure is recorded
      # and the next reconcile reroutes them to fallbacks via blackout.
      feed =
        Enum.reduce(connected, state.feed, fn relay, feed ->
          missing = Map.fetch!(missing_by_relay, relay)
          open = Map.get(feed, relay, %{})
          new_subs = open_feed_chunks(relay, MapSet.to_list(missing))
          Map.put(feed, relay, Map.merge(open, new_subs))
        end)

      %{state | feed: feed}
    end
  end

  defp open_feed_chunks(relay, pubkeys) do
    pubkeys
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce(%{}, fn chunk, acc ->
      since = Notes.since_for_filter(kinds: @feed_kinds, authors: chunk)
      limit = Notes.default_limit()

      with {:ok, sub} <-
             NostrEx.create_sub(authors: chunk, kinds: @feed_kinds, since: since, limit: limit),
           :ok <- NostrEx.listen(sub),
           {:ok, sub_id, _failures} <- NostrEx.send_sub(sub, send_via: [relay]) do
        Logger.info("SubManager: feed sub on #{relay} for #{length(chunk)} pubkey(s)")
        Map.put(acc, sub_id, MapSet.new(chunk))
      else
        {:error, :no_relays, _relays} ->
          Logger.error("SubManager: no relays connected for feed sub on #{relay}")
          acc
        {:error, reason, _failures} ->
          Logger.error("SubManager: failed to open feed sub on #{relay}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp close_all_feed_subs(state) do
    Enum.each(state.feed, fn {_relay, subs} ->
      Enum.each(Map.keys(subs), &NostrEx.close_sub/1)
    end)

    %{state | feed: %{}}
  end

  defp heal_dead_relays(state) do
    {_connected, dead} = Relay.connected(Map.keys(state.feed))

    if dead == [] do
      state
    else
      Logger.info("SubManager: reconnecting dead feed relays: #{Enum.join(dead, ", ")}")
      {:ok, _connected, failed} = Relay.maybe_connect_relays(dead)
      state = record_relay_failures(state, failed)

      # Subscriptions on dead relays are gone relay-side and in NostrEx's
      # RelayAgent; drop them from state so reconcile reopens them.
      %{state | feed: Map.drop(state.feed, dead)}
    end
  end

  ## Helpers

  defp follow_profiles(identity) do
    case Profile.get_by_pubkey(identity) do
      {:ok, profile} -> Repo.preload(profile, :following).following
      {:error, _} -> []
    end
  end

  defp fallback_relays do
    Application.get_env(:mist, :fallback_relays, @default_fallback_relays)
  end

  defp valid_relay_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["ws", "wss"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp evict_sub(state, relay_host, sub_id) do
    feed_url =
      Enum.find(Map.keys(state.feed), fn url -> Relay.relay_name(url) == relay_host end)

    feed =
      if feed_url do
        subs = Map.delete(state.feed[feed_url], sub_id)
        if map_size(subs) == 0, do: Map.delete(state.feed, feed_url), else: Map.put(state.feed, feed_url, subs)
      else
        state.feed
      end

    named =
      Map.new(state.named, fn {name, id} -> {name, id} end)
      |> Map.reject(fn {_name, id} -> id == sub_id end)

    meta_sub = if state.meta_sub == sub_id, do: nil, else: state.meta_sub

    %{state | feed: feed, named: named, meta_sub: meta_sub}
  end

  defp cancel_named_sub(state, name) do
    case Map.get(state.named, name) do
      nil ->
        state

      sub_id ->
        NostrEx.close_sub(sub_id)
        Logger.debug("SubManager: cancelled named subscription #{name} -> #{sub_id}")
        %{state | named: Map.delete(state.named, name)}
    end
  end

  defp prepare_subscription(%NostrEx.Subscription{} = sub, opts) do
    relay_opt = opts[:relays] || opts[:send_via]
    send_opts = if relay_opt, do: [send_via: relay_opt], else: []
    {:ok, {sub, send_opts}}
  end

  defp prepare_subscription(filters, opts) when is_list(filters) do
    case NostrEx.create_sub(filters) do
      {:ok, sub} -> prepare_subscription(sub, opts)
      {:error, reason} -> {:error, reason}
    end
  end
end
