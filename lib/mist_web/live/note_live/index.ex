defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Event

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, stream(socket, :notes, [])}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Notes")
    |> assign(:note, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Note")
    |> assign(:note, %Event{})
  end

  @impl true
  def handle_info(%{event: "note", payload: note}, socket) do
    {:noreply, stream_insert(socket, :notes, %{
      id: note.id,
      pubkey: note.pubkey,
      content: note.content
    })}
  end

  def handle_info({MistWeb.NoteLive.FormComponent, {:saved, note}}, socket) do
    {:noreply, stream_insert(socket, :notes, note)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
