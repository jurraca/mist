defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Event

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
    {:ok, stream(socket, :notes, [])}
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
  def handle_info(%Nostr.Event{content: content} = note, socket) do
    {:noreply, stream_insert(socket, :notes, %{
      id: note.id,
      pubkey: note.pubkey,
      content: note.content
    }, at: 0)}
  end

  @impl true
  def handle_info({MistWeb.NoteLive.FormComponent, {:saved, note}}, socket) do
    {:noreply, stream_insert(socket, :notes, note)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
