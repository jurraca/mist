defmodule Mist.Jobs.FindUserRelays do
  use GenServer
  alias Mist.Profile
  alias Mist.Notes
  alias Mist.Nostr.EventHandler
  alias Mist.Relay

  require Logger

  @directories ["wss://purplepag.es"]
  @popular_relays [
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]
  @kinds [10002]
  @batch_size 50
  @subscription_timeout 30_000
  @max_events_per_subscription 200
  @repeat_interval 30 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    Process.send_after(self(), :run_discovery, 5_000)
    {:ok, state}
  end

  def handle_info(:run_discovery, state) do
    Task.start(fn -> run_discovery_batch() end)

    Process.send_after(self(), :run_discovery, @repeat_interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @doc """
  Manually trigger relay discovery for profiles that need it
  """
  def run do
    GenServer.cast(__MODULE__, :run_now)
  end

  def handle_cast(:run_now, state) do
    Task.start(fn -> run_discovery_batch() end)
    {:noreply, state}
  end

  defp run_discovery_batch do
    Logger.info("Starting relay discovery batch")

    profiles = Profile.fetch_profiles_for_relay_discovery(@batch_size)

    if Enum.empty?(profiles) do
      Logger.info("No profiles need relay discovery at this time")
    else
      Logger.info("Found #{length(profiles)} profiles for relay discovery")
      pubkeys = Enum.map(profiles, & &1.pubkey)

      search_relays(pubkeys, @directories, "directories")
      remaining_pubkeys = Profile.fetch_pubkeys_without_relays(pubkeys)

      if not Enum.empty?(remaining_pubkeys) do
        Logger.info(
          "#{length(remaining_pubkeys)} profiles still need relays, trying popular relays"
        )

        search_relays(remaining_pubkeys, @popular_relays, "popular relays")
      end

      update_check_timestamps(profiles)
    end
  end

  defp search_relays([], _relay_list, relay_type) do
    Logger.info("No profiles to search for #{relay_type}")
  end

  defp search_relays(pubkeys, relay_list, relay_type) do
    Logger.info("Searching #{relay_type} for #{length(pubkeys)} profiles")

    case Relay.maybe_connect_relays(relay_list) do
      {:ok, []} ->
        Logger.error("Failed to connect to any #{relay_type}")

      {:ok, connected_relays} ->
        subscribe_and_wait(pubkeys, connected_relays, relay_type)
    end
  end

  defp subscribe_and_wait(pubkeys, relay_list, relay_type) do
    since = Notes.since_for_filter(kinds: @kinds, authors: pubkeys)
    filter = [authors: pubkeys, kinds: @kinds, since: since]

    with {:ok, sub} <- NostrEx.create_sub(filter),
         :ok <- NostrEx.listen(sub),
         {:ok, sub_id} <- NostrEx.send_sub(sub, send_via: relay_list) do
      Logger.info("Subscribed to #{relay_type} with sub_id: #{sub_id}")
      handle_subscription_events(sub_id, relay_list, relay_type)
    else
      {:error, reason} ->
        Logger.error("Failed to subscribe to #{relay_type}: #{inspect(reason)}")
    end
  end

  defp handle_subscription_events(sub_id, relay_list, relay_type) do
    start_time = System.monotonic_time(:millisecond)
    handle_events_loop(sub_id, relay_list, relay_type, 0, 0, start_time)
  end

  defp handle_events_loop(sub_id, relay_list, relay_type, event_count, eose_count, start_time) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - start_time

    cond do
      elapsed > @subscription_timeout ->
        Logger.info("Subscription to #{relay_type} timed out after #{elapsed}ms")
        NostrEx.close_sub(sub_id)

      event_count >= @max_events_per_subscription ->
        Logger.info("Max events (#{@max_events_per_subscription}) reached for #{relay_type}")
        NostrEx.close_sub(sub_id)

      true ->
        receive do
          {:event, ^sub_id, event} ->
            case process_relay_event(event) do
              :ok ->
                handle_events_loop(
                  sub_id,
                  relay_list,
                  relay_type,
                  event_count + 1,
                  eose_count,
                  start_time
                )

              :error ->
                handle_events_loop(
                  sub_id,
                  relay_list,
                  relay_type,
                  event_count,
                  eose_count,
                  start_time
                )
            end

          {:eose, ^sub_id, relay_host} ->
            Logger.debug("EOSE from #{relay_host} (#{event_count} events processed)")
            new_eose_count = eose_count + 1

            if new_eose_count >= length(relay_list) do
              Logger.info(
                "Finished subscription to #{relay_type} - received EOSE from all relays (#{event_count} events)"
              )

              NostrEx.close_sub(sub_id)
            else
              handle_events_loop(
                sub_id,
                relay_list,
                relay_type,
                event_count,
                new_eose_count,
                start_time
              )
            end

          other ->
            Logger.debug("Received unexpected message: #{inspect(other)}")
            handle_events_loop(sub_id, relay_list, relay_type, event_count, eose_count, start_time)
        after
          5_000 ->
            handle_events_loop(sub_id, relay_list, relay_type, event_count, eose_count, start_time)
        end
    end
  end

  defp process_relay_event(%{kind: 10002, pubkey: pubkey} = event) do
    Logger.debug("Processing kind 10002 relay event for #{String.slice(pubkey, 0, 8)}...")
    EventHandler.process_event(event)
  end

  defp process_relay_event(event) do
    Logger.debug("Received non-relay event kind: #{event.kind}")
    EventHandler.process_event(event)
  end

  defp update_check_timestamps(profiles) do
    pubkeys = Enum.map(profiles, & &1.pubkey)

    case Profile.update_relay_check_timestamp(pubkeys) do
      {count, _} ->
        if count != length(pubkeys) do
          Logger.warning("Expected to update #{length(pubkeys)} relay check timestamps, updated #{count}")
        end
    end

    Logger.info("Updated relay check timestamps for #{length(pubkeys)} profiles")
  end
end
