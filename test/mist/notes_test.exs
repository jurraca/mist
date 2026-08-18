defmodule Mist.NotesTest do
  use Mist.DataCase, async: true

  import Mist.NostrFixtures

  alias Mist.{Notes, Repo}
  alias Mist.Nostr.{Event, Tags}

  defp interaction_fixture(kind, note_id, attrs \\ %{}) do
    event =
      event_fixture(%{
        kind: kind,
        pubkey: Map.get(attrs, :pubkey, unique_pubkey()),
        content: Map.get(attrs, :content, "")
      })

    {:ok, _} =
      Repo.insert(
        Tags.changeset(%Tags{}, %{event_id: event.id, key: "e", value: note_id, rest: []})
      )

    event
  end

  defp reply_fixture(parent_id, attrs \\ %{}) do
    attrs = Map.new(attrs)

    event =
      event_fixture(%{
        kind: 1,
        pubkey: Map.get(attrs, :pubkey, unique_pubkey()),
        content: Map.get(attrs, :content, "reply"),
        created_at: Map.get(attrs, :created_at, System.os_time(:second))
      })

    rest = if attrs[:mention], do: ["mention"], else: []

    {:ok, _} =
      Repo.insert(
        Tags.changeset(%Tags{}, %{event_id: event.id, key: "e", value: parent_id, rest: rest})
      )

    event
  end

  describe "counts_for/1" do
    test "returns empty map for no note ids" do
      assert Notes.counts_for([]) == %{}
    end

    test "notes without interactions are absent" do
      assert Notes.counts_for([unique_event_id()]) == %{}
    end

    test "counts reactions, boosts, and zaps for a note" do
      note = event_fixture()

      interaction_fixture(7, note.event_id)
      interaction_fixture(7, note.event_id)
      interaction_fixture(6, note.event_id)
      interaction_fixture(9735, note.event_id)

      counts = Notes.counts_for([note.event_id])

      assert %{reaction_count: 2, boost_count: 1, zap_amount: 1000} = counts[note.event_id]
    end

    test "does not count interactions referencing other notes" do
      note = event_fixture()
      other = event_fixture()

      interaction_fixture(7, note.event_id)
      interaction_fixture(7, other.event_id)

      assert %{reaction_count: 1} = Notes.counts_for([note.event_id])[note.event_id]
    end

    test "does not count kind-1 replies as interactions" do
      note = event_fixture()
      reply = event_fixture()

      {:ok, _} =
        Repo.insert(
          Tags.changeset(%Tags{}, %{event_id: reply.id, key: "e", value: note.event_id, rest: []})
        )

      assert Notes.counts_for([note.event_id]) == %{}
    end

    test "batches over multiple notes" do
      a = event_fixture()
      b = event_fixture()

      interaction_fixture(7, a.event_id)
      interaction_fixture(6, b.event_id)

      counts = Notes.counts_for([a.event_id, b.event_id])

      assert %{reaction_count: 1} = counts[a.event_id]
      assert %{boost_count: 1} = counts[b.event_id]
    end
  end

  describe "note_view/1" do
    test "builds the canonical shape from a stored event" do
      note = event_fixture(%{content: "hello"})
      interaction_fixture(7, note.event_id)

      view = Notes.note_view(note)

      assert %{
               content: "hello",
               kind: 1,
               reaction_count: 1,
               boost_count: 0,
               zap_amount: 0,
               author: nil,
               bot: false,
               tags: []
             } = view

      assert view.id == note.event_id
      assert view.pubkey == note.pubkey
      assert view.created_at == note.created_at
    end

    test "normalizes nil content to empty string" do
      note = event_fixture(%{content: nil})
      assert Notes.note_view(note).content == ""
    end

    test "builds the same shape from a fresh NostrCore.Event" do
      stored = event_fixture(%{content: "from relay"})

      {:ok, tag} = NostrCore.Tag.create("e", "abc123")

      fresh = %NostrCore.Event{
        id: stored.event_id,
        pubkey: stored.pubkey,
        kind: 1,
        content: "from relay",
        created_at: DateTime.from_unix!(stored.created_at),
        tags: [tag],
        sig: stored.sig
      }

      view = Notes.note_view(fresh)

      assert view.id == stored.event_id
      assert view.created_at == stored.created_at
      assert view.content == "from relay"
      assert view.tags == [%{type: "e", data: "abc123", info: []}]
    end

    test "includes author profile data when present" do
      author = profile_fixture(%{name: "alice"})
      note = event_fixture(%{pubkey: author.pubkey})

      assert %{author: "alice", bot: false} = Notes.note_view(note)
    end
  end

  describe "list_conversations/3" do
    test "returns empty list for empty pubkeys" do
      assert Notes.list_conversations([], System.os_time(:second) - 3600) == []
    end

    test "returns parent and reply when they reply to each other in-network" do
      author = profile_fixture()
      parent = event_fixture(%{pubkey: author.pubkey, content: "parent"})
      reply = reply_fixture(parent.event_id, pubkey: author.pubkey)

      since = System.os_time(:second) - 3600
      views = Notes.list_conversations([author.pubkey], since)

      assert length(views) == 2
      ids = Enum.map(views, & &1.id)
      assert parent.event_id in ids
      assert reply.event_id in ids
    end

    test "excludes notes without replies" do
      author = profile_fixture()
      _lonely = event_fixture(%{pubkey: author.pubkey, content: "no replies"})

      since = System.os_time(:second) - 3600
      assert Notes.list_conversations([author.pubkey], since) == []
    end

    test "excludes replies to notes outside the network" do
      friend = profile_fixture()
      rando = profile_fixture()
      parent_by_rando = event_fixture(%{pubkey: rando.pubkey})
      _reply_by_friend = reply_fixture(parent_by_rando.event_id, pubkey: friend.pubkey)

      since = System.os_time(:second) - 3600
      assert Notes.list_conversations([friend.pubkey], since) == []
    end

    test "includes parents older than the window when in-network" do
      author = profile_fixture()
      now = System.os_time(:second)
      old_parent = event_fixture(%{pubkey: author.pubkey, created_at: now - 7200})
      _recent_reply = reply_fixture(old_parent.event_id, pubkey: author.pubkey, created_at: now)

      views = Notes.list_conversations([author.pubkey], now - 3600)

      assert length(views) == 2
      assert old_parent.event_id in Enum.map(views, & &1.id)
    end

    test "excludes conversations entirely outside the window" do
      author = profile_fixture()
      now = System.os_time(:second)
      old_parent = event_fixture(%{pubkey: author.pubkey, created_at: now - 7200})
      _old_reply = reply_fixture(old_parent.event_id, pubkey: author.pubkey, created_at: now - 7000)

      assert Notes.list_conversations([author.pubkey], now - 3600) == []
    end

    test "mention edges do not make a conversation" do
      author = profile_fixture()
      parent = event_fixture(%{pubkey: author.pubkey})
      _mention = reply_fixture(parent.event_id, pubkey: author.pubkey, mention: true)

      since = System.os_time(:second) - 3600
      assert Notes.list_conversations([author.pubkey], since) == []
    end

    test "participants carry DB-computed counts" do
      author = profile_fixture()
      parent = event_fixture(%{pubkey: author.pubkey})
      _reply = reply_fixture(parent.event_id, pubkey: author.pubkey)
      interaction_fixture(7, parent.event_id)

      since = System.os_time(:second) - 3600
      views = Notes.list_conversations([author.pubkey], since)

      parent_view = Enum.find(views, &(&1.id == parent.event_id))
      assert parent_view.reaction_count == 1
    end

    test "results are ordered newest first" do
      author = profile_fixture()
      now = System.os_time(:second)
      parent = event_fixture(%{pubkey: author.pubkey, created_at: now - 100})
      _reply = reply_fixture(parent.event_id, pubkey: author.pubkey, created_at: now)

      views = Notes.list_conversations([author.pubkey], now - 3600)

      assert [first, _second] = views
      assert first.created_at >= List.last(views).created_at
    end
  end

  describe "conversation_edges/1" do
    test "builds deduplicated edges from e-tags" do
      parent = event_fixture()
      reply = reply_fixture(parent.event_id)

      edges = Notes.conversation_edges(Repo.preload([parent, reply], :tags))

      assert edges == [%{source: parent.event_id, target: reply.event_id, type: "reply"}]
    end

    test "skips mentions and empty tag values" do
      parent = event_fixture()
      mention = reply_fixture(parent.event_id, mention: true)

      empty_tag_event = event_fixture()

      {1, _} =
        Repo.insert_all(Tags, [%{event_id: empty_tag_event.id, key: "e", value: "", rest: []}])

      edges =
        Notes.conversation_edges(Repo.preload([parent, mention, empty_tag_event], :tags))

      assert edges == []
    end

    test "includes edges whose source is outside the given set (caller filters)" do
      reply = reply_fixture("some-external-parent")
      edges = Notes.conversation_edges(Repo.preload([reply], :tags))
      assert [%{source: "some-external-parent", target: _, type: "reply"}] = edges
    end
  end

  describe "list_recent_by_pubkeys/1" do
    test "notes carry DB-computed counts" do
      author = profile_fixture()
      note = event_fixture(%{pubkey: author.pubkey})
      interaction_fixture(7, note.event_id)
      interaction_fixture(9735, note.event_id)

      [view] = Notes.list_recent_by_pubkeys([author.pubkey])

      assert view.id == note.event_id
      assert view.reaction_count == 1
      assert view.zap_amount == 1000
    end
  end
end
