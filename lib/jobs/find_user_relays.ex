defmodule Mist.Jobs.FindUserRelays do
  alias Mist.Profile
  alias Mist.Nostr.EventHandler

  require Logger

  @directories ["wss://purplepag.es"]

  @popular_relays [
    "wss://nos.lol",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]

  @kinds [10002]

  def run do
    Profile.fetch_profiles_without_relays()
    |> batch_and_subscribe(@directories)

    profiles_left = Profile.fetch_profiles_without_relays()
    count = Enum.count(profiles_left)
    if count > 0 do
       Logger.info("Finished searching initial directories, #{count} profiles left to find. Searching popular relays...")
       profiles_left |> batch_and_subscribe(@popular_relays)
    end
  end

  defp batch_and_subscribe(profiles, relays) do
    profiles
    |> Enum.map(&Map.get(&1, :pubkey))
    |> Enum.chunk_every(100)
    |> Enum.each(fn batch -> subscribe_batch(batch, relays) end)
  end

  defp subscribe_batch(pubkeys, relay_list) do
    Task.start(fn ->
      subscribe_and_handle_events(pubkeys, relay_list)
    end)
  end

  defp subscribe_and_handle_events(pubkeys, relay_list) do
    Logger.info("Starting subscription for #{length(pubkeys)} pubkeys on #{inspect(relay_list)}")
    filter = [authors: pubkeys, kinds: @kinds]

    case Mist.Relay.maybe_connect_relays(relay_list) do
      {:ok, _} ->
        case NostrEx.send_subscription(filter, send_via: relay_list) do
          {:ok, sub_id} ->
            Logger.info("Subscribed to relays with sub_id: #{sub_id}")
            handle_events(sub_id, relay_list)

          {:error, reason} ->
            Logger.error("Failed to subscribe to relays: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to connect to relays: #{inspect(reason)}")
    end
  end

  defp handle_events(sub_id, relay_list) do
    handle_events(sub_id, relay_list, 0, 0)
  end

  defp handle_events(sub_id, relay_list, event_count, eose_count) do
    receive do
      {:event, ^sub_id, event} ->
        case event.kind do
          10002 ->
            Logger.info("Processing kind 10002 event: #{event.pubkey}")
            EventHandler.process_event(event)

          _ ->
            Logger.debug("Received event kind: #{event.kind}")
            EventHandler.process_event(event)
        end

        new_event_count = event_count + 1

        if new_event_count >= 100 do
          Logger.info("Processed 100 events, closing subscription")
          NostrEx.close_sub(sub_id)
          :ok
        else
          handle_events(sub_id, relay_list, new_event_count, eose_count)
        end

      {:eose, ^sub_id, relay_host} ->
        Logger.info("End of stored events from #{relay_host} (#{event_count} events processed)")
        new_eose_count = eose_count + 1

        if new_eose_count >= length(relay_list) do
          Logger.info("Finished subscription task - received EOSE from all relays")
          NostrEx.close_subscription(sub_id)
          :ok
        else
          handle_events(sub_id, relay_list, event_count, new_eose_count)
        end

      other ->
        Logger.debug("Received: #{inspect(other)}")
        handle_events(sub_id, relay_list, event_count, eose_count)
    end
  end
end
