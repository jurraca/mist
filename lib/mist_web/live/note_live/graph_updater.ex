defmodule MistWeb.NoteLive.GraphUpdater do
  @moduledoc """
  Create and update the conversation graph data.

  The graph only contains *conversations* (per PLAN.md: no notes without
  replies). `from_notes/1` is fed pre-filtered conversation participants
  (`Mist.Notes.list_conversations/3`). Live updates go through `flush/2`,
  which admits a note only when it shares a reply edge with the existing
  graph or with another candidate (held/batched) note — so a new
  conversation can appear live (parent + reply promoted together) while
  reply-less notes are held (and may be promoted later by a reply).
  """

  @held_limit 500

  # ids/link_keys are memoized index sets kept in sync with nodes/links, so
  # flush stays proportional to the batch size rather than the graph size.
  def new(), do: %{nodes: [], links: [], held: %{}, ids: MapSet.new(), link_keys: MapSet.new()}

  def from_notes(notes) do
    {nodes, links} = build_changes(notes)
    links = valid_links(links, nodes)

    %{
      nodes: nodes,
      links: links,
      held: %{},
      ids: MapSet.new(nodes, & &1.id),
      link_keys: MapSet.new(links, &{&1.source, &1.target})
    }
  end

  def queue(pending, note), do: [note | pending]

  def flush(graph, pending) do
    unique =
      pending
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(graph.ids, &1.id))
      |> Enum.reject(&Map.has_key?(graph.held, &1.id))

    {new_nodes, new_links, held} = add_conversation_nodes(graph, unique)

    held =
      if map_size(held) > @held_limit do
        held |> Enum.take(@held_limit) |> Map.new()
      else
        held
      end

    unique_links = Enum.reject(new_links, &MapSet.member?(graph.link_keys, {&1.source, &1.target}))

    updated = %{
      graph
      | nodes: new_nodes ++ graph.nodes,
        links: unique_links ++ graph.links,
        held: held,
        ids: Enum.reduce(new_nodes, graph.ids, &MapSet.put(&2, &1.id)),
        link_keys: Enum.reduce(unique_links, graph.link_keys, &MapSet.put(&2, {&1.source, &1.target}))
    }

    {updated, new_nodes, unique_links}
  end

  def update_counts(graph, note_id, counts) do
    nodes = Enum.map(graph.nodes, fn n ->
      if n.id == note_id, do: Map.merge(n, counts), else: n
    end)
    %{graph | nodes: nodes}
  end

  # Merge profile data (author/picture) into every node by this pubkey.
  # Nil values never clobber what a node already has.
  def update_profile(graph, pubkey, profile) do
    update = Map.reject(profile, fn {_, v} -> is_nil(v) end)

    nodes = Enum.map(graph.nodes, fn n ->
      if n.pubkey == pubkey, do: Map.merge(n, update), else: n
    end)

    %{graph | nodes: nodes}
  end

  # Full content is kept in the payload: the graph no longer renders text
  # previews next to nodes; the hover sidebar displays the complete note.
  def build_node(note) do
    %{
      id: note.id, pubkey: note.pubkey,
      author: Map.get(note, :author),
      picture: Map.get(note, :picture),
      content: note.content || "",
      type: "note", created_at: note.created_at,
      reaction_count: Map.get(note, :reaction_count, 0),
      boost_count: Map.get(note, :boost_count, 0),
      zap_amount: Map.get(note, :zap_amount, 0)
    }
  end

  def extract_reply_links(note) do
    note.tags
    |> Enum.filter(&(&1.type == "e" and is_binary(&1.data) and &1.data != ""))
    |> Enum.reject(&mention_tag?/1)
    |> Enum.map(fn %{data: ref_id} -> %{source: ref_id, target: note.id, type: "reply"} end)
    |> Enum.uniq()
  end

  ## Conversation-aware admission

  # Candidates = pending notes + currently held notes. A candidate joins the
  # graph iff its connected component (over reply edges) either touches the
  # existing graph or contains at least one other candidate.
  defp add_conversation_nodes(graph, pending_notes) do
    graph_ids = graph.ids

    candidates = pending_notes ++ Map.values(graph.held)
    candidate_ids = MapSet.new(candidates, & &1.id)

    # links whose target is a candidate (links always point candidate -> parent)
    links_by_candidate =
      Map.new(candidates, fn note -> {note.id, extract_reply_links(note)} end)

    # adjacency between candidates (undirected) + flag candidates touching the graph
    {adj, touches_graph} =
      Enum.reduce(candidates, {%{}, MapSet.new()}, fn note, {adj, touches} ->
        Enum.reduce(links_by_candidate[note.id], {adj, touches}, fn link, {adj, touches} ->
          cond do
            MapSet.member?(candidate_ids, link.source) ->
              {adj |> Map.update(link.source, [note.id], &[note.id | &1]) |> Map.update(note.id, [link.source], &[link.source | &1]),
               touches}

            MapSet.member?(graph_ids, link.source) ->
              {adj, MapSet.put(touches, note.id)}

            true ->
              {adj, touches}
          end
        end)
      end)

    # connected components over candidates; admit if size > 1 or touches graph
    {admitted_ids, _visited} =
      Enum.reduce(candidate_ids, {MapSet.new(), MapSet.new()}, fn id, {admitted, visited} ->
        if MapSet.member?(visited, id) do
          {admitted, visited}
        else
          component = bfs_component(id, adj)

          joins? =
            MapSet.size(component) > 1 or
              Enum.any?(component, &MapSet.member?(touches_graph, &1))

          if joins? do
            {MapSet.union(admitted, component), MapSet.union(visited, component)}
          else
            {admitted, MapSet.union(visited, component)}
          end
        end
      end)

    notes_by_id = Map.new(candidates, &{&1.id, &1})

    admitted =
      admitted_ids
      |> MapSet.to_list()
      |> Enum.map(&notes_by_id[&1])
      |> Enum.sort_by(& &1.created_at)

    all_ids = MapSet.union(graph_ids, admitted_ids)

    new_nodes = Enum.map(admitted, &build_node/1)

    new_links =
      admitted
      |> Enum.flat_map(&links_by_candidate[&1.id])
      |> Enum.filter(&MapSet.member?(all_ids, &1.source))
      |> Enum.uniq()

    held =
      candidates
      |> Enum.reject(&MapSet.member?(admitted_ids, &1.id))
      |> Map.new(&{&1.id, &1})

    {new_nodes, new_links, held}
  end

  defp bfs_component(start, adj) do
    do_bfs([start], adj, MapSet.new())
  end

  defp do_bfs([], _adj, visited), do: visited

  defp do_bfs([id | rest], adj, visited) do
    if MapSet.member?(visited, id) do
      do_bfs(rest, adj, visited)
    else
      neighbors = Map.get(adj, id, [])
      do_bfs(neighbors ++ rest, adj, MapSet.put(visited, id))
    end
  end

  defp mention_tag?(%{info: info}), do: "mention" in (info || [])

  defp valid_links(links, nodes) do
    ids = MapSet.new(nodes, & &1.id)
    Enum.filter(links, &(MapSet.member?(ids, &1.source) and MapSet.member?(ids, &1.target)))
  end

  defp build_changes(notes) do
    {Enum.map(notes, &build_node/1), Enum.flat_map(notes, &extract_reply_links/1)}
  end
end
