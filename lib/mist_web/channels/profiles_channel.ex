defmodule MistWeb.ProfilesChannel do
  use MistWeb, :channel

  alias Mist.Nostr.Dispatcher

  @impl true
  def join("profiles", pubkey, socket) do
      Dispatcher.subscribe_profile(pubkey)
      {:ok, socket}
  end

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (profiles:lobby).
  @impl true
  def handle_in("shout", payload, socket) do
    broadcast(socket, "shout", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(event, socket) do
    broadcast!(socket, "profiles", event)
    {:noreply, socket}
  end
end
