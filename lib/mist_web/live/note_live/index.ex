defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Event

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
    {:ok, socket
     |> stream(:notes, [])
     |> assign(:graph_data, %{nodes: [], links: []})
     |> assign(:view_mode, :list)}
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
  def handle_info(%{} = note_data, socket) do
    new_socket = socket
    |> stream_insert(:notes, note_data, at: 0)
    |> update_graph_data(note_data)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, String.to_atom(mode))}
  end

  defp update_graph_data(socket, note) do
    current_graph = socket.assigns.graph_data

    new_node = %{
      id: note.id,
      pubkey: note.pubkey,
      content: String.slice(note.content, 0, 50) <> "...",
      type: "note",
      created_at: note.created_at
    }

    reply_links = extract_reply_links(note)

    updated_graph = %{
      nodes: [new_node | current_graph.nodes],
      links: reply_links ++ current_graph.links
    }

    assign(socket, :graph_data, updated_graph)
  end

  defp extract_reply_links(note) do
    note.tags
    |> Enum.filter(fn tag -> tag.type == "e" end)
    |> Enum.map(fn %{data: referenced_note_id, info: _rest} ->
      %{
        source: referenced_note_id,
        target: note.id,
        type: "reply"
      }
    end)
  end

  @impl true
  def handle_info({MistWeb.NoteLive.FormComponent, {:saved, note}}, socket) do
    {:noreply, stream_insert(socket, :notes, note)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
