
defmodule Mist.Nostr.Initializer do
  @moduledoc """
  Handles initialization tasks for the Nostr application.
  """

  use GenServer
  require Logger
  alias Mist.Profile
  alias Mist.Nostr.Dispatcher

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state, {:continue, :initialize}}
  end

  @impl GenServer
  def handle_continue(:initialize, state) do
    case wait_for_signer_ready() do
      :ok ->
        setup_follows_subscription()
        {:noreply, state}
      :timeout ->
        Logger.warning("Signer not ready after timeout, skipping follows subscription")
        {:noreply, state}
    end
  end

  @doc """
  Sets up initial subscriptions for the user's follows.
  Called during application startup after the signer is ready.
  """
  def setup_follows_subscription do
    with {:ok, %Profile.Profile{} = my_profile} <- Profile.get_my_profile(),
         write_relay_map when map_size(write_relay_map) > 0 <- Profile.get_write_relays_by_relay(my_profile.following) do

      relay_urls = Map.keys(write_relay_map)
      case Mist.Relay.maybe_connect_relays(relay_urls) do
        {:ok, _} ->
          Enum.each(write_relay_map, fn {relay_url, authors} ->
            filters = [%{kinds: [0, 3, 10002], authors: authors}]
            Dispatcher.subscribe(filters, relays: [relay_url])
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

  @doc """
  Waits for the signer to be ready before proceeding with initialization.
  """
  def wait_for_signer_ready(attempts \\ 10) do
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
end
