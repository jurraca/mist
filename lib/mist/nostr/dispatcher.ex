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

  def subscribe_profile(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_profile, pubkey, opts})
  end

  def subscribe_follows(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_follows, pubkey, opts})
  end

  def subscribe_notes(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_notes, pubkey, opts})
  end

  @impl GenServer
  def handle_continue(_arg, state) do
    case wait_for_signer_ready() do
      :ok ->
        subscribe_to_follows_events()
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

  defp subscribe_to_follows_events do
    with {:ok, %Profile.Profile{} = my_profile} <- Profile.get_my_profile(),
        write_relay_map = Profile.get_write_relays_by_relay(my_profile.following) do

        case write_relay_map |> Map.keys() |> Mist.Relay.maybe_connect_relays() do
          {:ok, _} ->
            sub_ids = Enum.map(write_relay_map, fn {relay_url, authors} ->
              case subscribe_to_relay_for_authors(relay_url, authors) do
                {:ok, sub_id} ->
                  Logger.debug("Subscribed to #{relay_url} for #{length(authors)} authors")
                  sub_id
                {:error, reason} ->
                  Logger.debug(reason)
              end
          end)

            {:ok, sub_ids}

          {:error, reason} ->
            Logger.debug(reason)
        end
      else
      {:error, _} ->
        Logger.debug("No profile set, skipping follows subscription")
    end
  end

  defp subscribe_to_relay_for_authors(relay_url, authors) do
    filter = [kinds: [0, 10002], authors: authors]
    Nostrbase.send_subscription([filter], send_via: [relay_url])
  end

  @impl GenServer
  def handle_cast({:subscribe_profile, pubkey, opts}, state) do
    Nostrbase.subscribe_profile(pubkey, send_via: opts[:relays])
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:subscribe_follows, pubkey, opts}, state) do
    Nostrbase.subscribe_follows(pubkey, send_via: opts[:relays])
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:subscribe_notes, pubkey, opts}, state) do
    Nostrbase.subscribe_notes(pubkey, send_via: opts[:relays])
    {:noreply, state}
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
