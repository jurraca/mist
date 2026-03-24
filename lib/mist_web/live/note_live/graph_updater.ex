defmodule MistWeb.NoteLive.GraphUpdater do
  @moduledoc """
  Create and update the graph data.
  """

  def new(), do: %{nodes: [], links: []}

  def from_notes(notes) do
    {nodes, links} = build_changes(notes)
    %{nodes: nodes, links: links}
  end

  def queue(pending, note), do: [note | pending]

  def flush(graph, pending) do
    existing_ids = MapSet.new(graph.nodes, & &1.id)
    unique = pending
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
    {new_nodes, new_links} = build_changes(unique)
    existing_link_keys = MapSet.new(graph.links, &{&1.source, &1.target})
    unique_links = Enum.reject(new_links, &MapSet.member?(existing_link_keys, {&1.source, &1.target}))
    updated = %{nodes: new_nodes ++ graph.nodes, links: unique_links ++ graph.links}
    {updated, new_nodes, unique_links}
  end

  def update_counts(graph, note_id, counts) do
    nodes = Enum.map(graph.nodes, fn n ->
      if n.id == note_id, do: Map.merge(n, counts), else: n
    end)
    %{graph | nodes: nodes}
  end

  def build_node(note) do
    %{
      id: note.id, pubkey: note.pubkey,
      content: String.slice(note.content, 0, 50) <> "...",
      type: "note", created_at: note.created_at,
      reaction_count: Map.get(note, :reaction_count, 0),
      boost_count: Map.get(note, :boost_count, 0),
      zap_amount: Map.get(note, :zap_amount, 0)
    }
  end

  def extract_reply_links(note) do
    note.tags
    |> Enum.filter(&(&1.type == "e"))
    |> Enum.map(fn %{data: ref_id} -> %{source: ref_id, target: note.id, type: "reply"} end)
  end

  defp build_changes(notes) do
    {Enum.map(notes, &build_node/1), Enum.flat_map(notes, &extract_reply_links/1)}
  end
end
