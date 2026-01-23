defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Mist.Nostr.EventHandler
  alias NostrEx.Subscription

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{active_subscriptions: []}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  def subscribe(%Subscription{} = sub, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe, sub, opts})
  end

  def cancel_all_subscriptions do
    GenServer.cast(__MODULE__, :cancel_all)
  end

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    case NostrEx.send_sub(filters, send_via: opts[:relays]) do
      {:ok, sub_id} ->
        Logger.debug("Created subscription #{sub_id} with #{length(filters)} filters")
        {:noreply, %{state | active_subscriptions: [sub_id | state.active_subscriptions]}}
      {:error, reason} ->
        Logger.error("Failed to create subscription: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(:cancel_all, state) do
    Enum.each(state.active_subscriptions, fn sub_id ->
      NostrEx.close_sub(sub_id)
      Logger.debug("Cancelled subscription #{sub_id}")
    end)
    {:noreply, %{state | active_subscriptions: []}}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    Task.start(fn -> EventHandler.process_event(event) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:eose, sub_id, _relay}, state) do
    Logger.info("EOSE for #{sub_id}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end