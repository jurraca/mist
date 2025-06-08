defmodule Mist.Jobs.FindUserRelays do
  alias Mist.Profile
  alias Mist.Nostr.EventHandler

  require Logger

  @popular_relays [
    "wss://nos.lol",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nostr.bitcoiner.social"
  ]

  @kinds [10002]

  def run do
    Profile.fetch_profiles_without_relays()
    |> Enum.map(&Map.get(&1, :pubkey))
    |> Enum.take(100)
    |> subscribe()
  end

  defp subscribe(pubkeys) do
    Task.start(fn ->
      subscribe_and_handle(pubkeys, @kinds)
    end)
  end

  defp subscribe_and_handle(pubkeys, kinds) do
    Logger.info("Starting subscription task.")
    filter = [authors: pubkeys, kinds: kinds, limit: 50]

    case Mist.Relay.maybe_connect_relays(@popular_relays) do
      {:ok, _} ->
        case Nostrbase.send_subscription(filter, send_via: @popular_relays) do
          {:ok, sub_id} ->
            Logger.info("Subscribed with sub_id: #{sub_id}")
            handle_in()

          {:error, reason} ->
            Logger.error("Failed to subscribe: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to connect to relay: #{inspect(reason)}")
    end
  end

  defp handle_in(count \\ 0)
  defp handle_in(4) do
    Logger.info("Finished subscription task")
    :ok
  end

  defp handle_in(count) do
    receive do
      {:event, _sub_id, event} ->
        case event.kind do
          10002 ->
            Logger.info("Processing kind 10002 event from: #{event.pubkey}")
            EventHandler.process_event(event)

          _ ->
            Logger.debug("Received event kind: #{event.kind}")
            EventHandler.process_event(event)
        end

        handle_in(0)

      {:eose, sub_id, relay_host} ->
        Logger.info("End of stored events")
        Nostrbase.close_sub("wss://" <> relay_host, sub_id)
        handle_in(count + 1)

      other ->
        Logger.debug("Received: #{inspect(other)}")
        handle_in()
    end
  end
end
