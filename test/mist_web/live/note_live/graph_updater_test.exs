defmodule MistWeb.NoteLive.GraphUpdaterTest do
  use ExUnit.Case, async: true

  alias MistWeb.NoteLive.GraphUpdater

  defp make_note(id, content \\ "hello", tags \\ []) do
    %{
      id: id,
      pubkey: "pk_#{id}",
      content: content,
      created_at: ~N[2024-01-01 00:00:00],
      tags: tags,
      reaction_count: 0,
      boost_count: 0,
      zap_amount: 0
    }
  end

  defp reply_tag(ref_id), do: %{type: "e", data: ref_id, info: []}

  describe "new/0" do
    test "returns empty graph" do
      assert GraphUpdater.new() == %{nodes: [], links: []}
    end
  end

  describe "from_notes/1" do
    test "builds graph from notes list" do
      note = make_note("n1", "some content")
      graph = GraphUpdater.from_notes([note])
      assert length(graph.nodes) == 1
      assert hd(graph.nodes).id == "n1"
      assert graph.links == []
    end

    test "builds links from reply tags when both notes are present" do
      n1 = make_note("n1")
      n2 = make_note("n2", "reply", [reply_tag("n1")])
      graph = GraphUpdater.from_notes([n1, n2])
      assert length(graph.links) == 1
      assert hd(graph.links) == %{source: "n1", target: "n2", type: "reply"}
    end

    test "drops links to notes not in the set (dangling links crash d3)" do
      note = make_note("n2", "reply", [reply_tag("n1")])
      graph = GraphUpdater.from_notes([note])
      assert graph.links == []
    end

    test "ignores e-tags marked as mentions" do
      n1 = make_note("n1")
      n2 = make_note("n2", "mentions n1", [%{type: "e", data: "n1", info: ["mention"]}])
      graph = GraphUpdater.from_notes([n1, n2])
      assert graph.links == []
    end

    test "returns empty graph for empty list" do
      assert GraphUpdater.from_notes([]) == %{nodes: [], links: []}
    end
  end

  describe "queue/2" do
    test "prepends note to pending list" do
      note = make_note("n1")
      assert GraphUpdater.queue([], note) == [note]
    end

    test "maintains order with multiple notes" do
      n1 = make_note("n1")
      n2 = make_note("n2")
      pending = GraphUpdater.queue([], n1)
      pending = GraphUpdater.queue(pending, n2)
      assert pending == [n2, n1]
    end
  end

  describe "flush/2" do
    test "adds new notes to empty graph" do
      graph = GraphUpdater.new()
      note = make_note("n1")
      {updated, new_nodes, new_links} = GraphUpdater.flush(graph, [note])
      assert length(updated.nodes) == 1
      assert length(new_nodes) == 1
      assert new_links == []
    end

    test "deduplicates against existing graph nodes" do
      note = make_note("n1")
      graph = GraphUpdater.from_notes([note])
      {updated, new_nodes, _new_links} = GraphUpdater.flush(graph, [note])
      assert length(updated.nodes) == 1
      assert new_nodes == []
    end

    test "deduplicates within pending batch" do
      graph = GraphUpdater.new()
      note = make_note("n1")
      {updated, new_nodes, _new_links} = GraphUpdater.flush(graph, [note, note])
      assert length(updated.nodes) == 1
      assert length(new_nodes) == 1
    end

    test "deduplicates links against existing links" do
      n1 = make_note("n1")
      n2 = make_note("n2", "reply", [reply_tag("n1")])
      graph = GraphUpdater.from_notes([n1, n2])
      {updated, _new_nodes, new_links} = GraphUpdater.flush(graph, [n2])
      assert new_links == []
      assert length(updated.links) == 1
    end

    test "drops pending links whose endpoints are unknown" do
      graph = GraphUpdater.new()
      reply = make_note("n2", "reply", [reply_tag("unknown-parent")])
      {updated, new_nodes, new_links} = GraphUpdater.flush(graph, [reply])
      assert length(new_nodes) == 1
      assert new_links == []
      assert updated.links == []
    end

    test "keeps pending links when the parent already exists in the graph" do
      parent = make_note("n1")
      graph = GraphUpdater.from_notes([parent])
      reply = make_note("n2", "reply", [reply_tag("n1")])
      {_updated, _new_nodes, new_links} = GraphUpdater.flush(graph, [reply])
      assert new_links == [%{source: "n1", target: "n2", type: "reply"}]
    end

    test "reverses pending order so oldest-first" do
      graph = GraphUpdater.new()
      n1 = make_note("n1")
      n2 = make_note("n2")
      pending = [n2, n1]
      {updated, new_nodes, _} = GraphUpdater.flush(graph, pending)
      assert length(updated.nodes) == 2
      assert length(new_nodes) == 2
    end
  end

  describe "update_counts/3" do
    test "updates counts on matching node" do
      note = make_note("n1")
      graph = GraphUpdater.from_notes([note])
      counts = %{reaction_count: 5, boost_count: 2, zap_amount: 1000}
      updated = GraphUpdater.update_counts(graph, "n1", counts)
      node = hd(updated.nodes)
      assert node.reaction_count == 5
      assert node.boost_count == 2
      assert node.zap_amount == 1000
    end

    test "does not modify other nodes" do
      n1 = make_note("n1")
      n2 = make_note("n2")
      graph = GraphUpdater.from_notes([n1, n2])
      updated = GraphUpdater.update_counts(graph, "n1", %{reaction_count: 9})
      n2_node = Enum.find(updated.nodes, &(&1.id == "n2"))
      assert n2_node.reaction_count == 0
    end
  end

  describe "build_node/1" do
    test "truncates content to 50 chars with ellipsis" do
      long = String.duplicate("a", 60)
      note = make_note("n1", long)
      node = GraphUpdater.build_node(note)
      assert node.content == String.duplicate("a", 50) <> "..."
    end

    test "short content still gets ellipsis appended" do
      note = make_note("n1", "hi")
      node = GraphUpdater.build_node(note)
      assert node.content == "hi..."
    end

    test "includes default counts" do
      note = make_note("n1")
      node = GraphUpdater.build_node(note)
      assert node.reaction_count == 0
      assert node.boost_count == 0
      assert node.zap_amount == 0
    end

    test "uses provided counts from note" do
      note = make_note("n1") |> Map.put(:reaction_count, 3)
      node = GraphUpdater.build_node(note)
      assert node.reaction_count == 3
    end
  end

  describe "extract_reply_links/1" do
    test "returns empty list when no e-type tags" do
      note = make_note("n1", "no tags")
      assert GraphUpdater.extract_reply_links(note) == []
    end

    test "returns links for e-type tags" do
      note = make_note("n2", "reply", [reply_tag("n1")])
      links = GraphUpdater.extract_reply_links(note)
      assert links == [%{source: "n1", target: "n2", type: "reply"}]
    end

    test "ignores non-e type tags" do
      tags = [%{type: "p", data: "pk123", info: []}, reply_tag("n1")]
      note = make_note("n2", "reply", tags)
      links = GraphUpdater.extract_reply_links(note)
      assert length(links) == 1
      assert hd(links).source == "n1"
    end

    test "returns multiple links for multiple e-type tags" do
      tags = [reply_tag("n1"), reply_tag("n0")]
      note = make_note("n2", "multi-reply", tags)
      links = GraphUpdater.extract_reply_links(note)
      assert length(links) == 2
    end
  end
end
