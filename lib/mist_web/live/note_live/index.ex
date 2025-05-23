defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, stream(socket, :notes, [])}
    end
  end

  @impl true
  def handle_info(%{event: "note", payload: note}, socket) do
    {:noreply, stream_insert(socket, :notes, %{
      id: note.id,
      pubkey: note.pubkey,
      content: note.content
    })}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
