defmodule MistWeb.NoteLive.IndexTest do
  use MistWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mist.NostrFixtures

  alias Mist.{Notes, Profile}

  describe "list view rendering" do
    setup :setup_identity

    test "notes stored in the DB before mount render in the list view", %{conn: conn} do
      me = :persistent_term.get(:my_profile_pubkey)
      author = profile_fixture(%{name: "alice"})
      follows_fixture(me, author.pubkey)

      # Note exists in the DB before the LiveView mounts — mount loads it
      # into the notes stream while view_mode is still :graph.
      event_fixture(%{pubkey: author.pubkey, content: "stored note from db"})

      {:ok, index_live, _html} = live(conn, ~p"/")

      html = render_click(index_live, "toggle_view", %{"mode" => "list"})
      assert html =~ "stored note from db"
    end

    test "batch flush firing while in graph mode still shows notes after toggling", %{conn: conn} do
      me = :persistent_term.get(:my_profile_pubkey)
      author = profile_fixture(%{name: "bob"})
      follows_fixture(me, author.pubkey)

      {:ok, index_live, _html} = live(conn, ~p"/")

      note =
        Notes.note_view(%NostrCore.Event{
          id: unique_event_id(),
          pubkey: author.pubkey,
          kind: 1,
          content: "flushed while hidden",
          created_at: DateTime.utc_now(),
          tags: [],
          sig: "00"
        })

      # The note arrives while the list container is absent (graph mode);
      # the 250ms batch flush fires while still hidden.
      Phoenix.PubSub.broadcast(Mist.PubSub, "notes", note)
      Process.sleep(400)

      html = render_click(index_live, "toggle_view", %{"mode" => "list"})
      assert html =~ "flushed while hidden"
    end
  end

  describe "profiles-topic events" do
    setup :setup_identity

    test "raw kind-3 follow-list events do not crash the view", %{conn: conn} do
      # The author is a direct follow, so any scope-based guard alone would
      # not keep the event out — only the kind: 1 match does.
      me = :persistent_term.get(:my_profile_pubkey)
      followed = profile_fixture()
      follows_fixture(me, followed.pubkey)

      {:ok, index_live, _html} = live(conn, ~p"/")

      event = %NostrCore.Event{
        id: unique_event_id(),
        pubkey: followed.pubkey,
        kind: 3,
        content: "",
        created_at: DateTime.utc_now(),
        tags: [%NostrCore.Tag{type: "p", data: unique_pubkey(), info: []}],
        sig: "00"
      }

      # Before the fix this matched the note clause (NostrCore.Event has
      # id/pubkey/content), entered the notes stream, and crashed the view
      # with KeyError :picture when the template rendered.
      Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", event)

      assert render(index_live) =~ "List"
    end

    test "kind-1 note views stream into the list view after the batch flush", %{conn: conn} do
      me = :persistent_term.get(:my_profile_pubkey)
      author = profile_fixture(%{name: "alice"})
      follows_fixture(me, author.pubkey)

      {:ok, index_live, _html} = live(conn, ~p"/")
      render_click(index_live, "toggle_view", %{"mode" => "list"})

      now = System.os_time(:second)

      note_older =
        Notes.note_view(%NostrCore.Event{
          id: unique_event_id(),
          pubkey: author.pubkey,
          kind: 1,
          content: "older note",
          created_at: DateTime.from_unix!(now - 100),
          tags: [],
          sig: "00"
        })

      note_newer =
        Notes.note_view(%NostrCore.Event{
          id: unique_event_id(),
          pubkey: author.pubkey,
          kind: 1,
          content: "newer note",
          created_at: DateTime.from_unix!(now),
          tags: [],
          sig: "00"
        })

      # Deliver out of order, with a duplicate copy of the older note —
      # the batch must dedup, sort oldest-first, and insert in one flush.
      Phoenix.PubSub.broadcast(Mist.PubSub, "notes", note_newer)
      Phoenix.PubSub.broadcast(Mist.PubSub, "notes", note_older)
      Phoenix.PubSub.broadcast(Mist.PubSub, "notes", note_older)

      html = assert_eventually(fn -> render(index_live) end, ~r/older note/, 1_000)
      assert html =~ "newer note"

      # Newest on top: "newer" appears before "older" in the rendered list.
      {newer_pos, _} = :binary.match(html, "newer note")
      {older_pos, _} = :binary.match(html, "older note")
      assert newer_pos < older_pos
    end

    defp assert_eventually(fun, pattern, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      assert_eventually_loop(fun, pattern, deadline)
    end

    defp assert_eventually_loop(fun, pattern, deadline) do
      html = fun.()

      if Regex.match?(pattern, html) or System.monotonic_time(:millisecond) > deadline do
        assert Regex.match?(pattern, html)
        html
      else
        Process.sleep(25)
        assert_eventually_loop(fun, pattern, deadline)
      end
    end

    test "kind-0 profile updates still reach the view", %{conn: conn} do
      me = :persistent_term.get(:my_profile_pubkey)
      author = profile_fixture(%{name: "bob"})
      follows_fixture(me, author.pubkey)

      {:ok, index_live, _html} = live(conn, ~p"/")

      {:ok, profile} =
        Profile.create_or_update_profile(%{
          "pubkey" => author.pubkey,
          "name" => "bob-updated"
        })

      Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", profile)

      # No crash — the Profile struct handler is unaffected by the kind guard.
      assert render(index_live) =~ "List"
    end
  end
end
