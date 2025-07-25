
defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Mist.Nostr.EventHandler
  alias Mist.Profile

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state, {:continue, nil}}
  end

  def subscribe(filters, opts \\ []) when is_list(filters) do
    GenServer.cast(__MODULE__, {:subscribe, filters, opts})
  end

  def subscribe_profiles(pubkeys, opts \\ []) do
    pubkeys = if is_list(pubkeys), do: pubkeys, else: [pubkeys]
    filters = [%{kinds: [0, 10002], authors: pubkeys}]
    subscribe(filters, opts)
  end

  def subscribe_follows(pubkey, opts \\ []) do
    filters = [%{kinds: [3], authors: [pubkey]}]
    subscribe(filters, opts)
  end

  def subscribe_notes(pubkey, opts \\ []) do
    filters = [%{kinds: [1], authors: [pubkey]}]
    subscribe(filters, opts)
  end

  @impl GenServer
  def handle_continue(_arg, state) do
    case wait_for_signer_ready() do
      :ok ->
        setup_follows_subscription()
        {:noreply, state}
      :timeout ->
        Logger.warning("Signer not ready after timeout, skipping follows subscription")
        {:noreply, state}
    end
  end

  defp wait_for_signer_ready(attempts \\ 10) do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil when attempts > 0 ->
        Process.sleep(100)
        wait_for_signer_ready(attempts - 1)
      nil ->
        :timeout
      _pubkey ->
        :ok
    end
  end

  defp setup_follows_subscription do
    with {:ok, %Profile.Profile{} = my_profile} <- Profile.get_my_profile(),
         write_relay_map when map_size(write_relay_map) > 0 <- Profile.get_write_relays_by_relay(my_profile.following) do

      relay_urls = Map.keys(write_relay_map)
      case Mist.Relay.maybe_connect_relays(relay_urls) do
        {:ok, _} ->
          Enum.each(write_relay_map, fn {relay_url, authors} ->
            filters = [%{kinds: [0, 3, 10002], authors: authors}]
            subscribe(filters, relays: [relay_url])
            Logger.debug("Subscribed to #{relay_url} for #{length(authors)} authors")
          end)

        {:error, reason} ->
          Logger.debug("Failed to connect to relays: #{inspect(reason)}")
      end
    else
      {:error, _} ->
        Logger.debug("No profile set, skipping follows subscription")
      %{} ->
        Logger.debug("No write relays found for follows")
    end
  end

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    case NostrEx.send_subscription(filters, send_via: opts[:relays]) do
      {:ok, sub_id} ->
        Logger.debug("Created subscription #{sub_id} with #{length(filters)} filters")
        {:noreply, state}
      {:error, reason} ->
        Logger.error("Failed to create subscription: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    Task.start(fn -> EventHandler.process_event(event) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info("EOSE", state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
