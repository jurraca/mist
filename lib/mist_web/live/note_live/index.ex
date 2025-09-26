defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Event
  alias Mist.{Relay, Profile}
  alias Mist.Nostr.Dispatcher

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
    Phoenix.PubSub.subscribe(Mist.PubSub, "note_counts")
    relays = Relay.list_relays()
    
    # Start with default subscription to all notes
    Dispatcher.subscribe_all_notes()
    
    {:ok, socket
     |> stream(:notes, [])
     |> assign(:graph_data, %{nodes: [], links: []})
     |> assign(:view_mode, :graph)
     |> assign(:subscription_filter, :all)
     |> assign(:available_relays, relays)
     |> assign(:selected_relay, nil)
     |> assign(:hashtag_filter, "")}
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
  def handle_info(%{note_id: note_id, counts: counts}, socket) do
    # Handle count updates by updating both graph data and stream
    new_socket = socket
    |> update_node_counts(note_id, counts)
    |> update_stream_counts(note_id, counts)
    
    {:noreply, new_socket}
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

  @impl true
  def handle_event("change_subscription_filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_atom(filter)
    {:noreply, 
      socket
      |> assign(:subscription_filter, filter_atom)
      |> update_subscription(filter_atom)}
  end

  @impl true 
  def handle_event("change_relay", %{"relay_url" => relay_url}, socket) do
    {:noreply, 
      socket
      |> assign(:selected_relay, relay_url)
      |> update_subscription(:single_relay, relay_url)}
  end

  @impl true
  def handle_event("change_hashtag", %{"hashtag" => hashtag}, socket) do
    {:noreply, 
      socket
      |> assign(:hashtag_filter, hashtag)
      |> update_subscription(:hashtag, hashtag)}
  end

  defp update_subscription(socket, filter_type, param \\ nil) do
    # Clear existing UI state first
    cleared_socket = socket
    |> stream(:notes, [], reset: true)
    |> assign(:graph_data, %{nodes: [], links: []})
    
    case filter_type do
      :all ->
        Dispatcher.subscribe_all_notes()
        
      :single_relay when is_binary(param) and param != "" ->
        Dispatcher.subscribe_relay_notes(param)
        
      :follows ->
        case Profile.get_my_profile() do
          {:ok, %{following: following}} when length(following) > 0 ->
            pubkeys = Enum.map(following, & &1.pubkey)
            Dispatcher.subscribe_follows_notes(pubkeys)
          _ ->
            # If no follows, fall back to all notes
            Dispatcher.subscribe_all_notes()
        end
        
      :hashtag when is_binary(param) and param != "" ->
        Dispatcher.subscribe_hashtag_notes(param)
        
      _ ->
        # Default case: subscribe to all notes
        Dispatcher.subscribe_all_notes()
    end
    
    cleared_socket
  end

  defp update_stream_counts(socket, note_id, counts) do
    # Update the note in the stream by using the note_id as the key
    # Phoenix LiveView will automatically replace the entry with the same id
    updated_note = Map.merge(%{id: note_id}, counts)
    stream_insert(socket, :notes, updated_note, dom_id: "notes-#{note_id}")
  end

  defp update_graph_data(socket, note) do
    current_graph = socket.assigns.graph_data

    new_node = %{
      id: note.id,
      pubkey: note.pubkey,
      content: String.slice(note.content, 0, 50) <> "...",
      type: "note",
      created_at: note.created_at,
      reaction_count: Map.get(note, :reaction_count, 0),
      boost_count: Map.get(note, :boost_count, 0),
      zap_amount: Map.get(note, :zap_amount, 0)
    }

    reply_links = extract_reply_links(note)

    updated_graph = %{
      nodes: [new_node | current_graph.nodes],
      links: reply_links ++ current_graph.links
    }

    assign(socket, :graph_data, updated_graph)
  end

  defp update_node_counts(socket, note_id, counts) do
    current_graph = socket.assigns.graph_data
    
    updated_nodes = 
      current_graph.nodes
      |> Enum.map(fn node ->
        if node.id == note_id do
          Map.merge(node, counts)
        else
          node
        end
      end)
    
    updated_graph = %{current_graph | nodes: updated_nodes}
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
