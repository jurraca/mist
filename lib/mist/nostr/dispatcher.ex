defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Nostr.Event

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
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
  def handle_info({:event, _sub_id, %Event{kind: 0} = event}, state) do
    dbg("DISPATCH RECV ")
    Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", event)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    # Broadcast to Phoenix PubSub based on event kind
    topic = "events:#{event.kind}"
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
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
