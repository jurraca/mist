defmodule MistWeb.NotesChannel do
  use MistWeb, :channel

  @impl true
  def join("notes", payload, socket) do
    Dispatcher.subscribe_notes(pubkey)
    {:ok, socket}
  end

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (notes:lobby).
  @impl true
  def handle_in("shout", payload, socket) do
    broadcast(socket, "shout", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(event, socket) do
    broadcast!(socket, "notes", event)
    {:noreply, socket}
  end
end
