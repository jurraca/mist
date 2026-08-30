defmodule Mist.Jobs.SecondHopNotes do
  @moduledoc """
  Periodically fetches notes and interactions from the second hop of the
  follow graph (profiles followed by my follows, ranked and capped — see
  `Profile.second_hop_pubkeys/2`) and persists them locally.

  Fetching is broad; rendering is not: the UI only shows second-hop notes
  that are reply-linked to a network note (see `Notes.list_conversations/3`
  and the NoteLive live-gate). Standalone second-hop posts are stored but
  never rendered.

  Fan-out is bounded: REQs go to the well-known fallback relays only (the
  same ones the feed uses for uncovered follows — connected on demand), not
  every connected relay, so per-relay concurrent REQ pressure stays low.
  `since` is incremental per chunk (latest stored event for those authors,
  floored at the default window), so each run only pulls what is new.
  Disarm by setting `second_hop_cap: 0`.
  """

  use GenServer

  alias Mist.{Notes, Profile, Relay}
  alias Mist.Nostr.{EventHandler, Identity}

  require Logger

  @kinds [1, 6, 7, 9735]
  @chunk_size 200
  @subscription_timeout 30_000
  @max_events_per_subscription 1000
  @initial_delay 60_000
  @repeat_interval 10 * 60 * 1000

  @well_known_relays [
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]

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
    cap = Application.get_env(:mist, :second_hop_cap, 300)

    with pubkey when is_binary(pubkey) <- Identity.current_pubkey(),
         secondary when secondary != [] <- Profile.second_hop_pubkeys(pubkey, cap),
         relays when relays != [] <- well_known_relays() do
      Logger.info("SecondHopNotes: fetching for #{length(secondary)} second-hop pubkey(s) via #{length(relays)} relay(s)")

      total =
        secondary
        |> Enum.chunk_every(@chunk_size)
        |> Enum.reduce(0, fn chunk, acc ->
          acc + subscribe_chunk(chunk, relays)
        end)

      Logger.info("SecondHopNotes: run complete (#{total} events processed)")
    else
      nil ->
        Logger.debug("SecondHopNotes: no identity yet, skipping")

      [] ->
        Logger.debug("SecondHopNotes: empty second hop or no connected relays, skipping")

      other ->
        Logger.debug("SecondHopNotes: skipping (#{inspect(other)})")
    end
  end

  # The well-known fallback relays, connected on demand. Nearly always
  # connected already (the feed fans uncovered follows onto them), and
  # maybe_connect_relays is idempotent for the rest. Bounding second-hop
  # REQs to these three keeps concurrent-REQ pressure off the niche write
  # relays.
  defp well_known_relays do
    case Relay.maybe_connect_relays(@well_known_relays) do
      {:ok, connected, _failed} -> connected
    end
  end

  defp subscribe_chunk(pubkeys, relays) do
    since = Notes.since_for_filter(kinds: @kinds, authors: pubkeys)
    filter = [authors: pubkeys, kinds: @kinds, since: since, limit: @max_events_per_subscription]

    with {:ok, sub} <- NostrEx.create_sub(filter),
         :ok <- NostrEx.listen(sub),
         {:ok, sub_id, _failures} <- NostrEx.send_sub(sub, send_via: relays) do
      Logger.info("SecondHopNotes: sub for #{length(pubkeys)} pubkey(s) since #{since}")
      drain(sub_id, length(relays), 0, 0, System.monotonic_time(:millisecond))
    else
      {:error, :no_relays, _relays} ->
        Logger.error("SecondHopNotes: no relays connected")
        0

      {:error, reason, _failures} ->
        Logger.error("SecondHopNotes: sub failed: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("SecondHopNotes: sub failed: #{inspect(reason)}")
        0
    end
  end

  defp drain(sub_id, relay_count, event_count, eose_count, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    cond do
      elapsed > @subscription_timeout ->
        Logger.info("SecondHopNotes: sub timed out after #{elapsed}ms (#{event_count} events)")
        NostrEx.close_sub(sub_id)
        event_count

      event_count >= @max_events_per_subscription ->
        Logger.info("SecondHopNotes: max events (#{@max_events_per_subscription}) reached")
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
