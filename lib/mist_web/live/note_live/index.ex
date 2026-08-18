defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.Nostr.{Event, Keys, SubManager}
  alias Mist.Notes
  alias Mist.Profile
  alias Mist.Subscriptions
  alias MistWeb.NoteLive.GraphUpdater

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
      Phoenix.PubSub.subscribe(Mist.PubSub, "note_counts")
    end

    relays = NostrEx.list_relays()

    {follow_lists, follow_pubkeys} =
      case Profile.get_my_profile() do
        {:ok, profile} ->
          lists = Profile.get_follow_lists(profile.id)
          pubkeys = Enum.map(profile.following, & &1.pubkey)
          {lists, pubkeys}

        _ ->
          {[], []}
      end

    stored_notes = Notes.list_recent_by_pubkeys(follow_pubkeys)

    initial_graph = GraphUpdater.from_notes(stored_notes)

    has_local_keypair = match?({:ok, _}, Keys.get_private_key())
    saved_subscriptions = Subscriptions.list_subscriptions()

    socket =
      socket
      |> stream(:notes, stored_notes)
      |> assign(:graph_data, initial_graph)
      |> assign(:view_mode, :list)
      |> assign(:subscription_filter, :following)
      |> assign(:available_relays, relays)
      |> assign(:selected_relay, nil)
      |> assign(:hashtag_filter, "")
      |> assign(:follow_lists, follow_lists)
      |> assign(:follow_pubkeys, follow_pubkeys)
      |> assign(:selected_list, nil)
      |> assign(:list_pubkeys, [])
      |> assign(:pending_graph_updates, [])
      |> assign(:batch_timer_ref, nil)
      |> assign(:has_local_keypair, has_local_keypair)
      |> assign(:saved_subscriptions, saved_subscriptions)
      |> assign(:selected_subscription_id, nil)
      |> assign(:notes_empty_message, empty_state_message(%{subscription_filter: :following, follow_pubkeys: follow_pubkeys, hashtag_filter: "", selected_relay: nil, selected_subscription_id: nil}, stored_notes))

    socket =
      if connected?(socket) do
        maybe_flash_no_relays(apply_subscription(socket), socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, url, socket) do
    {:noreply,
     socket
     |> assign(:current_path, URI.parse(url).path)
     |> apply_action(socket.assigns.live_action, params)}
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
    new_socket = socket
    |> update_node_counts(note_id, counts)
    |> update_stream_counts(note_id, counts)

    {:noreply, new_socket}
  end

  @impl true
  def handle_info(%{id: _, pubkey: _, content: _} = note_data, socket) do
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
  def handle_info({MistWeb.NoteLive.FormComponent, {:saved, note}}, socket) do
    {:noreply, stream_insert(socket, :notes, note, at: 0)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.batch_timer_ref do
      Process.cancel_timer(socket.assigns.batch_timer_ref)
    end
    SubManager.cancel_named_subscription(:notes_feed)
    :ok
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode =
      case mode do
        "list"  -> :list
        "graph" -> :graph
        _       -> :list
      end
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  @impl true
  def handle_event("change_subscription_filter", %{"filter" => filter}, socket) do
    cond do
      String.starts_with?(filter, "list:") ->
        [_, list_id] = String.split(filter, ":")
        list_id = String.to_integer(list_id)
        list_pubkeys = Profile.get_pubkeys_in_list(list_id)

        socket =
          socket
          |> assign(:subscription_filter, {:list, list_id})
          |> assign(:selected_list, list_id)
          |> assign(:list_pubkeys, list_pubkeys)
          |> assign(:selected_subscription_id, nil)
          |> clear_ui_state()
          |> reload_notes_for_filter()

        socket = maybe_flash_no_relays(apply_subscription(socket), socket)
        {:noreply, socket}

      String.starts_with?(filter, "subscription:") ->
        [_, sub_id] = String.split(filter, ":")
        sub_id = String.to_integer(sub_id)

        socket =
          socket
          |> assign(:subscription_filter, {:subscription, sub_id})
          |> assign(:selected_subscription_id, sub_id)
          |> assign(:selected_list, nil)
          |> clear_ui_state()
          |> reload_notes_for_filter()

        socket = maybe_flash_no_relays(apply_subscription(socket), socket)
        {:noreply, socket}

      true ->
        filter_atom =
          case filter do
            "all"          -> :all
            "following"    -> :following
            "single_relay" -> :single_relay
            "hashtag"      -> :hashtag
            _              -> :all
          end

        socket =
          socket
          |> assign(:subscription_filter, filter_atom)
          |> assign(:selected_list, nil)
          |> assign(:selected_subscription_id, nil)
          |> clear_ui_state()
          |> reload_notes_for_filter()

        socket = maybe_flash_no_relays(apply_subscription(socket), socket)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_relay", %{"relay_url" => relay_url}, socket) do
    socket =
      socket
      |> assign(:selected_relay, relay_url)
      |> clear_ui_state()
      |> reload_notes_for_filter()

    socket = maybe_flash_no_relays(apply_subscription(socket), socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_hashtag", %{"hashtag" => hashtag}, socket) do
    socket =
      socket
      |> assign(:hashtag_filter, hashtag)
      |> clear_ui_state()
      |> reload_notes_for_filter()

    socket = maybe_flash_no_relays(apply_subscription(socket), socket)
    {:noreply, socket}
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

  defp reload_notes_for_filter(socket) do
    notes =
      case socket.assigns.subscription_filter do
        :following              -> Notes.list_recent_by_pubkeys(socket.assigns.follow_pubkeys)
        {:list, _id}            -> Notes.list_recent_by_pubkeys(socket.assigns.list_pubkeys)
        :hashtag                -> Notes.list_recent_by_hashtag(socket.assigns.hashtag_filter)
        {:subscription, _id}    -> Notes.list_recent()
        _                       -> Notes.list_recent()
      end

    graph = GraphUpdater.from_notes(notes)

    socket
    |> stream(:notes, notes)
    |> assign(:graph_data, graph)
    |> push_event("graph_reset", graph)
    |> assign(:notes_empty_message, empty_state_message(socket.assigns, notes))
  end

  defp empty_state_message(_assigns, notes) when notes != [], do: nil
  defp empty_state_message(assigns, []) do
    case assigns.subscription_filter do
      :following when assigns.follow_pubkeys == [] ->
        "You're not following anyone yet. Visit your profile to add follows."
      :following ->
        "No recent notes from your follows."
      :hashtag when assigns.hashtag_filter in ["", nil] ->
        "Enter a hashtag above to search."
      :hashtag ->
        "No notes found for ##{assigns.hashtag_filter}."
      {:list, _} ->
        "No recent notes from this list."
      :single_relay when assigns.selected_relay in [nil, ""] ->
        "Select a relay from the dropdown above."
      :single_relay ->
        "No recent notes on #{assigns.selected_relay}."
      {:subscription, _} ->
        "No notes found for this subscription."
      _ ->
        "No notes found."
    end
  end

  defp maybe_flash_no_relays(:no_relays, socket) do
    put_flash(socket, :error, "No relays connected. Please connect to a relay first.")
  end

  defp maybe_flash_no_relays(_, socket), do: socket

  defp apply_subscription(socket) do
    connected_relays = NostrEx.list_relays()

    if connected_relays == [] do
      :no_relays
    else
      case build_subscription_filter(socket.assigns) do
        {:ok, filter_opts} ->
          {:ok, sub} = NostrEx.create_sub(filter_opts[:filters])
          opts = if filter_opts[:relay], do: [relays: [filter_opts[:relay]]], else: []
          SubManager.subscribe_with_name(:notes_feed, sub, opts)

        :skip ->
          SubManager.cancel_named_subscription(:notes_feed)
      end
    end
  end

  defp build_subscription_filter(assigns) do
    case assigns.subscription_filter do
      :all ->
        {:ok, %{filters: [kinds: [1]]}}

      :following ->
        pubkeys = assigns.follow_pubkeys
        if pubkeys == [], do: :skip, else: {:ok, %{filters: [kinds: [1], authors: pubkeys]}}

      :single_relay ->
        relay = assigns.selected_relay

        if relay && relay != "" do
          {:ok, %{filters: [kinds: [1]], relay: relay}}
        else
          :skip
        end

      :hashtag ->
        tag = assigns.hashtag_filter

        if tag && tag != "" do
          clean_tag = tag |> String.trim() |> String.downcase() |> String.replace(~r/^#/, "")
          {:ok, %{filters: [kinds: [1], "#t": [clean_tag]]}}
        else
          :skip
        end

      {:list, _list_id} ->
        pubkeys = assigns.list_pubkeys

        if pubkeys == [] do
          :skip
        else
          {:ok, %{filters: [kinds: [1], authors: pubkeys]}}
        end

      {:subscription, sub_id} ->
        build_saved_subscription_filter(sub_id)

      _ ->
        {:ok, %{filters: [kinds: [1]]}}
    end
  end

  defp build_saved_subscription_filter(sub_id) do
    try do
      sub = Subscriptions.get_subscription!(sub_id)
      filter = []

      filter =
        case sub.kinds do
          kinds when is_list(kinds) and kinds != [] -> Keyword.put(filter, :kinds, kinds)
          _ -> filter
        end

      filter =
        case sub.authors do
          authors when is_list(authors) and authors != [] ->
            Keyword.put(filter, :authors, authors)
          _ -> filter
        end

      filter =
        case sub.since do
          nil -> filter
          since -> Keyword.put(filter, :since, since)
        end

      filter =
        case sub.until do
          nil -> filter
          until -> Keyword.put(filter, :until, until)
        end

      filter =
        case sub.limit do
          nil -> filter
          limit -> Keyword.put(filter, :limit, limit)
        end

      filter =
        case sub.tags do
          nil -> filter
          tags when is_map(tags) ->
            Enum.reduce(tags, filter, fn {key, values}, acc ->
              case tag_filter_key(key) do
                nil -> acc
                tag_key -> Keyword.put(acc, tag_key, values)
              end
            end)
          _ -> filter
        end

      {:ok, %{filters: filter}}
    rescue
      Ecto.NoResultsError -> :skip
    end
  end

  defp tag_filter_key(<<c::utf8>>) when c in ?a..?z or c in ?A..?Z do
    String.to_atom("##{<<c::utf8>>}")
  end
  defp tag_filter_key(_), do: nil

  defp update_stream_counts(socket, note_id, counts) do
    push_event(socket, "update_note_counts", %{note_id: note_id, counts: counts})
  end

  defp queue_graph_update(socket, note) do
    pending = GraphUpdater.queue(socket.assigns.pending_graph_updates, note)
    socket = assign(socket, :pending_graph_updates, pending)

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
      {updated_graph, new_nodes, new_links} =
        GraphUpdater.flush(socket.assigns.graph_data, pending)

      socket
      |> assign(:graph_data, updated_graph)
      |> push_event("graph_update", %{nodes: new_nodes, links: new_links})
      |> assign(:pending_graph_updates, [])
    end
  end

  defp update_node_counts(socket, note_id, counts) do
    updated_graph = GraphUpdater.update_counts(socket.assigns.graph_data, note_id, counts)

    socket
    |> assign(:graph_data, updated_graph)
    |> push_event("graph_count_update", %{note_id: note_id, counts: counts})
  end
end
