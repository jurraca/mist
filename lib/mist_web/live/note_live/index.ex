defmodule MistWeb.NoteLive.Index do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.Nostr.{Event, Keys, SubManager}
  alias Mist.Notes
  alias Mist.Profile
  alias Mist.Subscriptions
  alias MistWeb.NoteLive.GraphUpdater

  @default_lookback_seconds 36 * 3_600

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mist.PubSub, "notes")
      Phoenix.PubSub.subscribe(Mist.PubSub, "note_counts")
      Phoenix.PubSub.subscribe(Mist.PubSub, "profiles")
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

    secondary_pubkeys = secondary_hop(follow_pubkeys)

    stored_notes = Notes.list_recent_by_pubkeys(follow_pubkeys)

    lookback_seconds = @default_lookback_seconds

    initial_graph =
      follow_pubkeys
      |> Notes.list_conversations(lookback_since(lookback_seconds), secondary_pubkeys: secondary_pubkeys)
      |> GraphUpdater.from_notes()

    has_local_keypair = match?({:ok, _}, Keys.get_private_key())
    saved_subscriptions = Subscriptions.list_subscriptions()

    socket =
      socket
      |> stream(:notes, stored_notes)
      |> assign(:graph_data, initial_graph)
      |> assign(:view_mode, :graph)
      |> assign(:subscription_filter, :following)
      |> assign(:available_relays, relays)
      |> assign(:selected_relay, nil)
      |> assign(:hashtag_filter, "")
      |> assign(:follow_lists, follow_lists)
      |> assign(:follow_pubkeys, follow_pubkeys)
      |> assign(:source_pubkeys, MapSet.new(follow_pubkeys))
      |> assign(:secondary_pubkeys, MapSet.new(secondary_pubkeys))
      |> assign(:lookback_seconds, lookback_seconds)
      |> assign(:selected_list, nil)
      |> assign(:list_pubkeys, [])
      |> assign(:pending_graph_updates, [])
      |> assign(:pending_stream_notes, [])
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

  # Only kind-1 note views (built by Notes.note_view/1, always kind: 1) are
  # notes. The "profiles" topic also delivers raw %NostrCore.Event{} kind-3
  # follow lists (see EventHandler), which must not enter the note stream —
  # they lack note-view keys (:picture, :author, counts) and would crash
  # the template.
  @impl true
  def handle_info(%{id: _, pubkey: _, content: _, kind: 1} = note_data, socket) do
    new_socket =
      socket
      |> maybe_stream_note(note_data)
      |> maybe_queue_graph_update(note_data)

    {:noreply, new_socket}
  end

  # Kind-0 arrivals (backfilled by SubManager) fill in author/picture on
  # graph nodes already on screen — no reload needed for avatars to appear.
  @impl true
  def handle_info(%Profile.Profile{} = profile, socket) do
    update = %{author: profile.name, picture: profile.picture}
    graph = GraphUpdater.update_profile(socket.assigns.graph_data, profile.pubkey, update)

    {:noreply,
     socket
     |> assign(:graph_data, graph)
     |> push_event("graph_profile_update", Map.put(update, :pubkey, profile.pubkey))}
  end

  @impl true
  def handle_info(:process_graph_batch, socket) do
    socket =
      socket
      |> process_batched_graph_updates()
      |> flush_pending_stream_notes()

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
  def handle_event("request_graph", _params, socket) do
    {:noreply, push_event(socket, "graph_reset", graph_payload(socket))}
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
          |> assign(:source_pubkeys, MapSet.new(list_pubkeys))
          |> assign(:secondary_pubkeys, MapSet.new())
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
          |> assign(:source_pubkeys, nil)
          |> assign(:secondary_pubkeys, MapSet.new())
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

        source_pubkeys = if filter_atom == :following, do: MapSet.new(socket.assigns.follow_pubkeys), else: nil

        secondary_pubkeys =
          if filter_atom == :following,
            do: MapSet.new(secondary_hop(socket.assigns.follow_pubkeys)),
            else: MapSet.new()

        socket =
          socket
          |> assign(:subscription_filter, filter_atom)
          |> assign(:selected_list, nil)
          |> assign(:selected_subscription_id, nil)
          |> assign(:source_pubkeys, source_pubkeys)
          |> assign(:secondary_pubkeys, secondary_pubkeys)
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
    |> assign(:graph_data, GraphUpdater.new())
    |> assign(:pending_graph_updates, [])
    |> assign(:pending_stream_notes, [])
    |> assign(:batch_timer_ref, nil)
  end

  defp lookback_since(lookback_seconds), do: System.os_time(:second) - lookback_seconds

  # Second hop of the follow graph (profiles my follows follow, ranked and
  # capped). Notes by these authors are fetched by Mist.Jobs.SecondHopNotes
  # and rendered only when reply-linked to a network note.
  defp secondary_hop([]), do: []

  defp secondary_hop(_follow_pubkeys) do
    case Profile.get_my_profile() do
      {:ok, profile} ->
        Profile.second_hop_pubkeys(profile.pubkey, Application.get_env(:mist, :second_hop_cap, 300))

      _ ->
        []
    end
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

    # Network sources (following / custom lists) show conversations only;
    # other sources fall back to a flat graph of the loaded notes.
    graph =
      case socket.assigns.source_pubkeys do
        nil ->
          GraphUpdater.from_notes(notes)

        pubkeys ->
          pubkeys
          |> MapSet.to_list()
          |> Notes.list_conversations(lookback_since(socket.assigns.lookback_seconds),
            secondary_pubkeys: MapSet.to_list(socket.assigns.secondary_pubkeys)
          )
          |> GraphUpdater.from_notes()
      end

    socket
    |> stream(:notes, notes)
    |> assign(:graph_data, graph)
    |> push_event("graph_reset", graph_payload(socket, graph))
    |> assign(:notes_empty_message, empty_state_message(socket.assigns, notes))
  end

  # window_seconds lets the client map conversation age onto the time axis.
  defp graph_payload(socket, graph \\ nil) do
    (graph || socket.assigns.graph_data)
    |> Map.take([:nodes, :links])
    |> Map.put(:window_seconds, socket.assigns.lookback_seconds)
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
        # since bounds relay backfill to the view's lookback window;
        # SubManager's feed subs handle longer-term continuity.
        pubkeys = assigns.follow_pubkeys
        since = lookback_since(assigns.lookback_seconds)
        if pubkeys == [], do: :skip, else: {:ok, %{filters: [kinds: [1], authors: pubkeys, since: since]}}

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
          {:ok, %{filters: [kinds: [1], authors: pubkeys, since: lookback_since(assigns.lookback_seconds)]}}
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

  # The list view is the follows' feed: network authors only (secondary-hop
  # notes live in the graph, not the list). Flat sources (nil source set)
  # show everything the subscription delivers, as before. Inserts are
  # batched (like the graph) via the shared 250ms timer: one diff per batch
  # instead of one per event, so relay backfill floods don't flood the
  # LiveView with renders.
  defp maybe_stream_note(socket, note) do
    if in_scope?(socket.assigns, note.pubkey) do
      socket
      |> update(:pending_stream_notes, &[note | &1])
      |> arm_batch_timer()
    else
      socket
    end
  end

  # Insert the batch oldest-first with at: 0 so the newest note ends up on
  # top and the batch lands roughly chronological. Stream inserts of an
  # existing dom_id move the item — dedup keeps relay copies from
  # re-inserting (P1 suppresses duplicate broadcasts; this guards against
  # re-delivery after a stream reset).
  defp flush_pending_stream_notes(%{assigns: %{pending_stream_notes: []}} = socket), do: socket

  defp flush_pending_stream_notes(socket) do
    notes =
      socket.assigns.pending_stream_notes
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.created_at, :asc)

    Enum.reduce(notes, socket, &stream_insert(&2, :notes, &1, at: 0))
    |> assign(:pending_stream_notes, [])
  end

  # The graph only shows conversations from the current network source and
  # inside the lookback window: drop live notes from outside the source
  # pubkey set or older than the window (relay backfill delivers far more
  # history than the view covers), and let GraphUpdater hold anything that
  # doesn't (yet) join a conversation. Secondary-hop authors pass only when
  # their note is reply-anchored to a network note.
  defp maybe_queue_graph_update(socket, note) do
    in_graph_scope =
      in_scope?(socket.assigns, note.pubkey) or anchored_secondary?(socket.assigns, note)

    if in_graph_scope and in_window?(socket.assigns, note) do
      socket
      |> queue_reply_parents(note)
      |> queue_graph_update(note)
    else
      socket
    end
  end

  # A secondary-authored note joins the graph only when it replies to a
  # network-authored note (which is persisted on arrival, so a DB lookup
  # settles it). The reverse case — a network note replying to a secondary
  # parent — is handled by queue_reply_parents when the network note arrives.
  # Only called when a source set exists (flat sources short-circuit in
  # maybe_queue_graph_update via in_scope?).
  defp anchored_secondary?(%{source_pubkeys: network, secondary_pubkeys: secondary}, note) do
    if MapSet.member?(secondary, note.pubkey) do
      ids = parent_ids(note.tags)
      ids != [] and Notes.by_event_ids(ids, MapSet.to_list(network)) != []
    else
      false
    end
  end

  defp in_window?(%{lookback_seconds: lookback}, %{created_at: ts}) when is_integer(ts) do
    ts >= System.os_time(:second) - lookback
  end

  defp in_window?(_, _), do: true

  defp in_scope?(%{source_pubkeys: nil}, _pubkey), do: true
  defp in_scope?(%{source_pubkeys: set}, pubkey), do: MapSet.member?(set, pubkey)

  # Non-mention "e" tag values of a note: the notes it replies to.
  defp parent_ids(tags) do
    for %{type: "e", data: id, info: info} <- tags,
        is_binary(id) and id != "",
        "mention" not in info,
        uniq: true,
        do: id
  end

  # If the note replies to parents we don't have in the graph (or held),
  # fetch in-network parents from the DB and queue them first, so the
  # conversation can form. Secondary-authored parents count too — a network
  # note replying to a second-hop note brings that parent into the graph,
  # anchored by construction.
  defp queue_reply_parents(socket, note) do
    known_ids =
      MapSet.new(socket.assigns.graph_data.nodes, & &1.id)
      |> MapSet.union(MapSet.new(Map.keys(socket.assigns.graph_data.held)))

    missing_parent_ids =
      note.tags
      |> Enum.filter(&(&1.type == "e" and is_binary(&1.data) and &1.data != ""))
      |> Enum.map(& &1.data)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known_ids, &1))

    if missing_parent_ids == [] do
      socket
    else
      source_pubkeys = socket.assigns.source_pubkeys

      parents =
        if source_pubkeys do
          authors =
            MapSet.union(source_pubkeys, socket.assigns.secondary_pubkeys)
            |> MapSet.to_list()

          Notes.by_event_ids(missing_parent_ids, authors)
        else
          []
        end

      Enum.reduce(parents, socket, fn parent, acc -> queue_graph_update(acc, parent) end)
    end
  end

  defp queue_graph_update(socket, note) do
    pending = GraphUpdater.queue(socket.assigns.pending_graph_updates, note)
    socket
    |> assign(:pending_graph_updates, pending)
    |> arm_batch_timer()
  end

  defp arm_batch_timer(socket) do
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
