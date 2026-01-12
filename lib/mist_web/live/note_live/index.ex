defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Event
  alias Mist.{Relay, Profile}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
      Phoenix.PubSub.subscribe(Mist.PubSub, "note_counts")
    end

    relays = Relay.list_relays()

    follow_lists =
      case Profile.get_my_profile() do
        {:ok, profile} -> Profile.get_follow_lists(profile.id)
        _ -> []
      end

    {:ok, socket
     |> stream(:notes, [])
     |> assign(:graph_data, %{nodes: [], links: []})
     |> assign(:view_mode, :list)
     |> assign(:subscription_filter, :all)
     |> assign(:available_relays, relays)
     |> assign(:selected_relay, nil)
     |> assign(:hashtag_filter, "")
     |> assign(:follow_lists, follow_lists)
     |> assign(:selected_list, nil)
     |> assign(:pending_graph_updates, [])
     |> assign(:batch_timer_ref, nil)}
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
    |> queue_graph_update(note_data)

    {:noreply, new_socket}
  end

  @impl true
  def handle_info(:process_graph_batch, socket) do
    socket = process_batched_graph_updates(socket)
    {:noreply, assign(socket, :batch_timer_ref, nil)}
  end

  @impl true
  def terminate(_reason, socket) do
    # Cancel any pending batch timer on LiveView termination
    if socket.assigns.batch_timer_ref do
      Process.cancel_timer(socket.assigns.batch_timer_ref)
    end
    :ok
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, String.to_atom(mode))}
  end

  @impl true
  def handle_event("change_subscription_filter", %{"filter" => filter}, socket) do
    cond do
      String.starts_with?(filter, "list:") ->
        [_, list_id] = String.split(filter, ":")
        list_id = String.to_integer(list_id)
        {:noreply,
         socket
         |> assign(:subscription_filter, {:list, list_id})
         |> assign(:selected_list, list_id)
         |> clear_ui_state()}

      true ->
        filter_atom = String.to_atom(filter)
        {:noreply,
         socket
         |> assign(:subscription_filter, filter_atom)
         |> assign(:selected_list, nil)
         |> clear_ui_state()}
    end
  end

  @impl true 
  def handle_event("change_relay", %{"relay_url" => relay_url}, socket) do
    {:noreply, 
      socket
      |> assign(:selected_relay, relay_url)
      |> clear_ui_state()}
  end

  @impl true
  def handle_event("change_hashtag", %{"hashtag" => hashtag}, socket) do
    {:noreply, 
      socket
      |> assign(:hashtag_filter, hashtag)
      |> clear_ui_state()}
  end

  defp clear_ui_state(socket) do
    if socket.assigns.batch_timer_ref do
      Process.cancel_timer(socket.assigns.batch_timer_ref)
    end

    socket
    |> stream(:notes, [], reset: true)
    |> assign(:graph_data, %{nodes: [], links: []})
    |> assign(:pending_graph_updates, [])
    |> assign(:batch_timer_ref, nil)
  end

  defp update_stream_counts(socket, note_id, counts) do
    # Update the note in the stream by using the note_id as the key
    # Phoenix LiveView will automatically replace the entry with the same id
    updated_note = Map.merge(%{id: note_id}, counts)
    stream_insert(socket, :notes, updated_note, dom_id: "notes-#{note_id}")
  end

  defp queue_graph_update(socket, note) do
    # Add note to pending updates
    pending = [note | socket.assigns.pending_graph_updates]
    socket = assign(socket, :pending_graph_updates, pending)
    
    # Schedule batch processing if not already scheduled
    if socket.assigns.batch_timer_ref == nil do
      timer_ref = Process.send_after(self(), :process_graph_batch, 250)
      assign(socket, :batch_timer_ref, timer_ref)
    else
      socket
    end
  end

  defp process_batched_graph_updates(socket) do
    pending = socket.assigns.pending_graph_updates
    
    if pending == [] do
      socket
    else
      current_graph = socket.assigns.graph_data
      existing_node_ids = MapSet.new(current_graph.nodes, & &1.id)
      
      # Deduplicate against existing graph nodes and within pending batch
      unique_notes = 
        pending
        |> Enum.reverse()
        |> Enum.uniq_by(& &1.id)
        |> Enum.reject(fn note -> MapSet.member?(existing_node_ids, note.id) end)
      
      # Build incremental changes (only truly new nodes/links)
      {new_nodes, new_links} = build_incremental_changes(unique_notes)
      
      # Deduplicate links against existing links
      existing_link_keys = MapSet.new(current_graph.links, fn link ->
        {link.source, link.target}
      end)
      
      unique_new_links = Enum.reject(new_links, fn link ->
        MapSet.member?(existing_link_keys, {link.source, link.target})
      end)
      
      # Update graph data
      updated_graph = %{
        nodes: new_nodes ++ current_graph.nodes,
        links: unique_new_links ++ current_graph.links
      }
      
      # Push incremental update to JS hook
      socket
      |> assign(:graph_data, updated_graph)
      |> push_event("graph_update", %{nodes: new_nodes, links: unique_new_links})
      |> assign(:pending_graph_updates, [])
    end
  end

  defp build_incremental_changes(notes) do
    nodes = Enum.map(notes, fn note ->
      %{
        id: note.id,
        pubkey: note.pubkey,
        content: String.slice(note.content, 0, 50) <> "...",
        type: "note",
        created_at: note.created_at,
        reaction_count: Map.get(note, :reaction_count, 0),
        boost_count: Map.get(note, :boost_count, 0),
        zap_amount: Map.get(note, :zap_amount, 0)
      }
    end)
    
    links = notes
    |> Enum.flat_map(&extract_reply_links/1)
    
    {nodes, links}
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
    
    # Push count update to JS hook
    socket
    |> assign(:graph_data, updated_graph)
    |> push_event("graph_count_update", %{note_id: note_id, counts: counts})
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
