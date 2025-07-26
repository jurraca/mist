defmodule Mist.Jobs.FindUserRelays do
  use GenServer
  alias Mist.Profile
  alias Mist.Nostr.EventHandler
  alias Mist.Relay

  require Logger

  @directories ["wss://purplepag.es"]
  @popular_relays [
    "wss://nos.lol",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]
  @kinds [10002]
  @batch_size 50
  @subscription_timeout 30_000
  @max_events_per_subscription 200

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    Process.send_after(self(), :run_discovery, 5_000)
    {:ok, state}
  end

  def handle_info(:run_discovery, state) do
    spawn_link(fn -> run_discovery_batch() end)

    Process.send_after(self(), :run_discovery, 30 * 60 * 1000)
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
    spawn_link(fn -> run_discovery_batch() end)
    {:noreply, state}
  end

  defp run_discovery_batch do
    Logger.info("Starting relay discovery batch")

    profiles = Profile.fetch_profiles_for_relay_discovery(@batch_size)

    if Enum.empty?(profiles) do
      Logger.info("No profiles need relay discovery at this time")
    else
      Logger.info("Found #{length(profiles)} profiles for relay discovery")
      search_relays(profiles, @directories, "directories")
      remaining_profiles = get_remaining_profiles(profiles)

      if not Enum.empty?(remaining_profiles) do
        Logger.info(
          "#{length(remaining_profiles)} profiles still need relays, trying popular relays"
        )

        search_relays(remaining_profiles, @popular_relays, "popular relays")
      end

      update_check_timestamps(profiles)
    end
  end

  defp get_remaining_profiles(original_profiles) do
    pubkeys = Enum.map(original_profiles, & &1.pubkey)

    Profile.fetch_profiles_without_relays()
    |> Enum.filter(fn profile -> profile.pubkey in pubkeys end)
  end

  defp search_relays([], _relay_list, relay_type) do
    Logger.info("No profiles to search for #{relay_type}")
  end

  defp search_relays(profiles, relay_list, relay_type) do
    Logger.info("Searching #{relay_type} for #{length(profiles)} profiles")

    case Relay.maybe_connect_relays(relay_list) do
      {:ok, connected_relays} ->
        pubkeys = Enum.map(profiles, & &1.pubkey)
        subscribe_and_wait(pubkeys, connected_relays, relay_type)

      {:error, reason} ->
        Logger.error("Failed to connect to #{relay_type}: #{inspect(reason)}")
    end
  end

  defp subscribe_and_wait(pubkeys, relay_list, relay_type) do
    filter = [authors: pubkeys, kinds: @kinds]

    case NostrEx.send_subscription(filter, send_via: relay_list) do
      {:ok, sub_id} ->
        Logger.info("Subscribed to #{relay_type} with sub_id: #{sub_id}")
        handle_subscription_events(sub_id, relay_list, relay_type)

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

    if elapsed > @subscription_timeout do
      Logger.info("Subscription to #{relay_type} timed out after #{elapsed}ms")
      NostrEx.close_subscription(sub_id)
    end

    if event_count >= @max_events_per_subscription do
      Logger.info("Max events (#{@max_events_per_subscription}) reached for #{relay_type}")
      NostrEx.close_subscription(sub_id)
    end

    receive do
      {:event, ^sub_id, event} ->
        case process_relay_event(event) do
          :ok ->
            new_event_count = event_count + 1

            handle_events_loop(
              sub_id,
              relay_list,
              relay_type,
              new_event_count,
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

          NostrEx.close_subscription(sub_id)
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

    Enum.each(pubkeys, fn pubkey ->
      case Profile.update_relay_check_timestamp(pubkey) do
        {1, _} -> :ok
        {0, _} -> Logger.warning("Failed to update timestamp for #{String.slice(pubkey, 0, 8)}")
      end
    end)

    Logger.info("Updated relay check timestamps for #{length(pubkeys)} profiles")
  end
end
