defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Mist.Nostr.EventHandler

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
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