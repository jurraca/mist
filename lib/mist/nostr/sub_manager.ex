defmodule Mist.Nostr.SubManager do
  @moduledoc """
  Single owner of all relay subscriptions.

  Two kinds of subscriptions live here:

    * **Named (ad-hoc) subscriptions** — UI/profile driven filters
      (`:notes_feed`, profile lookups, follow-list fetches). Managed via
      `subscribe/2`, `subscribe_with_name/3` and `cancel_named_subscription/1`.

    * **Feed subscriptions** — the follow-graph feed. A reconciliation loop
      computes the *desired* state from the DB (my follows → their NIP-65
      write relays, falling back to a set of well-known relays for follows
      with no known relays) and diffs it against the *actual* open
      subscriptions, opening and closing subscriptions as needed.

  Because `NostrEx.send_sub/2` registers the calling process as the receiver
  of subscription messages, this GenServer is the single event ingress for
  all subscriptions: every relay event is forwarded to
  `Mist.Nostr.EventHandler` in a supervised task.

  Reconciliation is triggered by: startup, `identity:switched`,
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
  @chunk_size 200
  @reconcile_debounce 1_000
  @tick_interval 5 * 60 * 1_000
  @identity_retry_interval 200
  @identity_max_retries 50

  @default_fallback_relays [
    "wss://nos.lol",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]

  defstruct named: %{},
            feed: %{},
            identity: nil,
            identity_retries: 0,
            reconcile_timer: nil

  # feed: %{relay_url => %{sub_id => MapSet.t(pubkey)}}
  # named: %{name => sub_id}

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

  @doc "Fetch kind 0 (profile) and kind 10002 (relay list) events for the given pubkeys."
  def subscribe_profiles(pubkeys, opts \\ []) when is_list(pubkeys) do
    kinds = [0, 10002]
    since = Notes.since_for_filter(kinds: kinds, authors: pubkeys)
    limit = Notes.default_limit()

    case NostrEx.create_sub(authors: pubkeys, kinds: kinds, since: since, limit: limit) do
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
    Phoenix.PubSub.subscribe(@pubsub, "identity:switched")
    Phoenix.PubSub.subscribe(@pubsub, "profile:new_follow")
    Phoenix.PubSub.subscribe(@pubsub, "profile:follow_list_updated")
    Phoenix.PubSub.subscribe(@pubsub, "profile:user_relays_updated")

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    Process.send_after(self(), :reconcile_tick, @tick_interval)
    {:noreply, resolve_identity(state)}
  end

  # The Signer sets the identity in its own handle_continue, which is not
  # ordered against ours — retry until it appears (same pattern as Initializer).
  defp resolve_identity(%{identity_retries: retries} = state) do
    case Identity.current_pubkey() do
      nil when retries < @identity_max_retries ->
        Process.send_after(self(), :retry_identity, @identity_retry_interval)
        %{state | identity_retries: retries + 1}

      nil ->
        Logger.warning("SubManager: no identity after #{retries} retries, feed subscriptions idle until identity is set")
        state

      pubkey ->
        reconcile(%{state | identity: pubkey})
    end
  end

  # ── Named / ad-hoc subscriptions ──────────────────────────

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    with {:ok, {sub, send_opts}} <- prepare_subscription(filters, opts),
         :ok <- NostrEx.listen(sub),
         {:ok, _sub_id} <- NostrEx.send_sub(sub, send_opts) do
      Logger.debug("SubManager: created subscription #{sub.id}")
    else
      {:error, reason} ->
        Logger.error("SubManager: failed to create subscription: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:subscribe_named, name, filters, opts}, state) do
    state = cancel_named_sub(state, name)

    with {:ok, {sub, send_opts}} <- prepare_subscription(filters, opts),
         :ok <- NostrEx.listen(sub),
         {:ok, _sub_id} <- NostrEx.send_sub(sub, send_opts) do
      Logger.debug("SubManager: created named subscription #{name} -> #{sub.id}")
      {:noreply, %{state | named: Map.put(state.named, name, sub.id)}}
    else
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

  # ── Reconciliation triggers ───────────────────────────────

  @impl GenServer
  def handle_info({:identity_switched, pubkey}, state) do
    Logger.info("SubManager: identity switched, resetting feed subscriptions")
    state = state |> close_all_feed_subs() |> Map.put(:identity, pubkey)
    {:noreply, schedule_reconcile(state)}
  end

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
    {:noreply, state |> heal_dead_relays() |> reconcile()}
  end

  def handle_info(:retry_identity, state) do
    {:noreply, resolve_identity(state)}
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

  # Relay-initiated CLOSE (rate limit, filter rejection, ...). Evict the sub
  # from state; the next reconcile tick reopens feed subs, and the UI
  # re-creates named subs on its next apply.
  def handle_info({:close, sub_id, relay_host}, state) do
    Logger.info("SubManager: #{relay_host} closed sub #{String.slice(sub_id, 0, 8)}")
    {:noreply, evict_sub(state, relay_host, sub_id)}
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
    desired = desired_feeds(state.identity)

    state
    |> close_feed_subs_for_undesired_relays(desired)
    |> open_feed_subs_for_missing(desired)
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

    Enum.reduce(uncovered, desired, fn pubkey, acc ->
      Enum.reduce(fallback_relays(), acc, fn relay, acc2 ->
        Map.update(acc2, relay, MapSet.new([pubkey]), &MapSet.put(&1, pubkey))
      end)
    end)
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
    # Compute missing pubkeys per relay first...
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

    # ...then connect to all needed relays concurrently (one batch)...
    {:ok, connected} = Relay.maybe_connect_relays(Map.keys(missing_by_relay))

    # ...and open subscriptions only on relays that are actually connected.
    feed =
      Enum.reduce(connected, state.feed, fn relay, feed ->
        missing = Map.fetch!(missing_by_relay, relay)
        open = Map.get(feed, relay, %{})
        new_subs = open_feed_chunks(relay, MapSet.to_list(missing))
        Map.put(feed, relay, Map.merge(open, new_subs))
      end)

    %{state | feed: feed}
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
           {:ok, sub_id} <- NostrEx.send_sub(sub, send_via: [relay]) do
        Logger.info("SubManager: feed sub on #{relay} for #{length(chunk)} pubkey(s)")
        Map.put(acc, sub_id, MapSet.new(chunk))
      else
        {:error, reason} ->
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
      Relay.maybe_connect_relays(dead)

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

    %{state | feed: feed, named: named}
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
