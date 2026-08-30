defmodule Mist.Jobs.FindFollowGraph do
  @moduledoc """
  Periodically fetches kind-3 (follow list) events for the identity's direct
  follows, so the DB learns who the follows follow — the second hop of the
  follow graph. Those second-hop profiles feed `Profile.second_hop_pubkeys/2`,
  which drives second-hop note fetching and rendering.

  Relay strategy: each follow's kind-3 lives on their write relays, so follows
  are grouped by NIP-65 write relay (`user_relays`). Follows without known
  write relays fall back to the relay hint from the identity's own kind-3
  p-tags (`profile.relay`), and finally to well-known relays.

  Kind-3 is replaceable: no `since` filter — a user's current list may be old,
  and relays return only the latest event per author. Events route through
  `EventHandler`, which persists `Follows` rows via `Profile.add_follow_list/2`
  (idempotent). The `profile:follow_list_updated` broadcasts only re-trigger
  SubManager reconciliation for the identity's own list, so this job causes
  no feed churn.
  """

  use GenServer

  alias Mist.{Profile, Repo}
  alias Mist.Nostr.{EventHandler, Identity}
  alias Mist.Relay

  require Logger

  @well_known_relays [
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]
  @kinds [3]
  @chunk_size 200
  @subscription_timeout 30_000
  @max_events_per_subscription 500
  @initial_delay 15_000
  @repeat_interval 6 * 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    Process.send_after(self(), :run, @initial_delay)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:run, state) do
    Task.start(fn -> run_batch() end)
    Process.send_after(self(), :run, @repeat_interval)
    {:noreply, state}
  end

  defp run_batch do
    with pubkey when is_binary(pubkey) <- Identity.current_pubkey(),
         {:ok, profile} <- Profile.get_by_pubkey(pubkey) do
      follows = Repo.preload(profile, :following).following

      if follows == [] do
        Logger.info("FindFollowGraph: no follows, skipping")
      else
        Logger.info("FindFollowGraph: fetching kind-3 for #{length(follows)} follow(s)")

        {groups, rest} = relay_groups(follows)

        total = fetch_groups(groups) + fetch_via_well_known(rest)

        Logger.info("FindFollowGraph: batch complete (#{total} events processed)")
      end
    else
      nil -> Logger.info("FindFollowGraph: no identity yet, skipping")
      {:error, :not_found} -> Logger.info("FindFollowGraph: identity profile missing, skipping")
    end
  end

  # Groups follows by where their kind-3 is most likely published: their
  # NIP-65 write relays first, then the relay hint carried in the identity's
  # own kind-3 p-tags. Returns {groups, rest} where groups is
  # %{relay_url => [pubkeys]} and rest the pubkeys with no hint at all.
  defp relay_groups(follows) do
    by_write_relay =
      follows
      |> Profile.get_write_relays_by_relay()
      |> Map.new(fn {relay, pubkeys} -> {relay, MapSet.new(pubkeys)} end)

    covered =
      by_write_relay
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    {hinted, rest} =
      follows
      |> Enum.reject(&MapSet.member?(covered, &1.pubkey))
      |> Enum.split_with(&valid_hint?(&1.relay))

    groups =
      Enum.reduce(hinted, by_write_relay, fn follow, acc ->
        Map.update(acc, follow.relay, MapSet.new([follow.pubkey]), &MapSet.put(&1, follow.pubkey))
      end)

    {groups, Enum.map(rest, & &1.pubkey)}
  end

  defp valid_hint?(relay) when is_binary(relay) do
    case URI.parse(relay) do
      %URI{scheme: scheme, host: host} -> scheme in ["ws", "wss"] and is_binary(host)
    end
  end

  defp valid_hint?(_), do: false

  # One kind-3 subscription per relay group (chunked); each follow's list is
  # fetched from the relay it is published on.
  defp fetch_groups(groups) do
    Enum.reduce(groups, 0, fn {relay, pubkeys}, total ->
      case Relay.maybe_connect_relays([relay]) do
        {:ok, [], _failed} ->
          Logger.warning("FindFollowGraph: could not connect to #{relay}, skipping its group")
          total

        {:ok, _connected, _failed} ->
          total + subscribe_and_wait(MapSet.to_list(pubkeys), [relay])
      end
    end)
  end

  # Follows with no relay hint at all: their kind-3 may still be on the
  # well-known relays. One sub via every connected fallback.
  defp fetch_via_well_known([]), do: 0

  defp fetch_via_well_known(pubkeys) do
    Logger.info("FindFollowGraph: #{length(pubkeys)} follow(s) via well-known relays")

    case Relay.maybe_connect_relays(@well_known_relays) do
      {:ok, [], _failed} ->
        Logger.warning("FindFollowGraph: no well-known relays connected")
        0

      {:ok, connected, _failed} ->
        subscribe_and_wait(pubkeys, connected)
    end
  end

  defp subscribe_and_wait([], _relay_list), do: 0

  defp subscribe_and_wait(pubkeys, relay_list) do
    pubkeys
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce(0, fn chunk, total ->
      total + subscribe_chunk(chunk, relay_list)
    end)
  end

  defp subscribe_chunk(pubkeys, relay_list) do
    filter = [authors: pubkeys, kinds: @kinds, limit: @max_events_per_subscription]

    with {:ok, sub} <- NostrEx.create_sub(filter),
         :ok <- NostrEx.listen(sub),
         {:ok, sub_id, _failures} <- NostrEx.send_sub(sub, send_via: relay_list) do
      Logger.info("FindFollowGraph: kind-3 sub for #{length(pubkeys)} pubkey(s) via #{inspect(relay_list)}")
      drain(sub_id, length(relay_list), 0, 0, System.monotonic_time(:millisecond))
    else
      {:error, :no_relays, _relays} ->
        Logger.error("FindFollowGraph: no relays connected for kind-3 sub")
        0

      {:error, reason, _failures} ->
        Logger.error("FindFollowGraph: kind-3 sub failed: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("FindFollowGraph: kind-3 sub failed: #{inspect(reason)}")
        0
    end
  end

  defp drain(sub_id, relay_count, event_count, eose_count, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    cond do
      elapsed > @subscription_timeout ->
        Logger.info("FindFollowGraph: sub timed out after #{elapsed}ms (#{event_count} events)")
        NostrEx.close_sub(sub_id)
        event_count

      event_count >= @max_events_per_subscription ->
        Logger.info("FindFollowGraph: max events (#{@max_events_per_subscription}) reached")
        NostrEx.close_sub(sub_id)
        event_count

      true ->
        receive do
          {:event, ^sub_id, event} ->
            EventHandler.process_event(event)
            drain(sub_id, relay_count, event_count + 1, eose_count, start_time)

          {:eose, ^sub_id, _relay_host} when eose_count + 1 >= relay_count ->
            NostrEx.close_sub(sub_id)
            event_count

          {:eose, ^sub_id, _relay_host} ->
            drain(sub_id, relay_count, event_count, eose_count + 1, start_time)

          _other ->
            drain(sub_id, relay_count, event_count, eose_count, start_time)
        after
          5_000 -> drain(sub_id, relay_count, event_count, eose_count, start_time)
        end
    end
  end
end
