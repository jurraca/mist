defmodule Mist.Nostr.EventTest do
  use Mist.DataCase

  alias Mist.Nostr.Event
  alias Mist.Notes

  import Mist.NostrFixtures

  @valid_pubkey String.duplicate("a", 64)
  @valid_event_id String.duplicate("b", 64)
  @valid_sig String.duplicate("c", 128)

  @valid_attrs %{
    event_id: @valid_event_id,
    pubkey: @valid_pubkey,
    created_at: 1_700_000_000,
    kind: 1,
    content: "hello world",
    sig: @valid_sig
  }

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      changeset = Event.changeset(%Event{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires event_id" do
      attrs = Map.delete(@valid_attrs, :event_id)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{event_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires pubkey" do
      attrs = Map.delete(@valid_attrs, :pubkey)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{pubkey: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires created_at" do
      attrs = Map.delete(@valid_attrs, :created_at)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{created_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires kind" do
      attrs = Map.delete(@valid_attrs, :kind)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{kind: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires content" do
      attrs = Map.delete(@valid_attrs, :content)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires sig" do
      attrs = Map.delete(@valid_attrs, :sig)
      changeset = Event.changeset(%Event{}, attrs)
      assert %{sig: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates pubkey length must be 64" do
      attrs = %{@valid_attrs | pubkey: "tooshort"}
      changeset = Event.changeset(%Event{}, attrs)
      assert %{pubkey: _} = errors_on(changeset)
    end

    test "validates event_id length must be 64" do
      attrs = %{@valid_attrs | event_id: "tooshort"}
      changeset = Event.changeset(%Event{}, attrs)
      assert %{event_id: _} = errors_on(changeset)
    end

    test "validates sig length must be 128" do
      attrs = %{@valid_attrs | sig: "tooshort"}
      changeset = Event.changeset(%Event{}, attrs)
      assert %{sig: _} = errors_on(changeset)
    end

    test "validates kind is >= 0" do
      attrs = %{@valid_attrs | kind: -1}
      changeset = Event.changeset(%Event{}, attrs)
      assert %{kind: _} = errors_on(changeset)
    end

    test "validates kind is < 65535" do
      attrs = %{@valid_attrs | kind: 65535}
      changeset = Event.changeset(%Event{}, attrs)
      assert %{kind: _} = errors_on(changeset)
    end

    test "enforces unique event_id" do
      event_fixture(%{event_id: @valid_event_id})

      assert {:error, changeset} =
               Repo.insert(
                 Event.changeset(%Event{}, %{@valid_attrs | sig: unique_sig()})
               )

      assert %{event_id: _} = errors_on(changeset)
    end
  end

  describe "change_note/2" do
    test "valid content produces valid changeset" do
      changeset = Event.change_note(%Event{}, %{content: "some note"})
      assert changeset.valid?
    end

    test "empty content is invalid" do
      changeset = Event.change_note(%Event{}, %{content: ""})
      refute changeset.valid?
    end

    test "missing content is invalid" do
      changeset = Event.change_note(%Event{}, %{})
      refute changeset.valid?
    end

    test "content over max length is invalid" do
      long = String.duplicate("a", 10_001)
      changeset = Event.change_note(%Event{}, %{content: long})
      refute changeset.valid?
    end

    test "content at max length is valid" do
      exact = String.duplicate("a", 10_000)
      changeset = Event.change_note(%Event{}, %{content: exact})
      assert changeset.valid?
    end
  end

  describe "format_attrs/1" do
    test "remaps id to event_id" do
      attrs = %{"id" => "abc123", "content" => "hello"}
      result = Notes.format_attrs(attrs)
      assert result["event_id"] == "abc123"
    end

    test "converts empty content to nil" do
      attrs = %{"id" => "abc123", "content" => ""}
      result = Notes.format_attrs(attrs)
      assert result["content"] == nil
    end

    test "preserves non-empty content" do
      attrs = %{"id" => "abc123", "content" => "hello"}
      result = Notes.format_attrs(attrs)
      assert result["content"] == "hello"
    end
  end

  describe "max_created_at/1" do
    test "returns nil when no events exist" do
      assert is_nil(Notes.max_created_at())
    end

    test "returns the max created_at timestamp" do
      event_fixture(%{created_at: 1_000_000})
      event_fixture(%{created_at: 2_000_000})
      event_fixture(%{created_at: 1_500_000})

      assert Notes.max_created_at() == 2_000_000
    end

    test "respects :kinds filter" do
      event_fixture(%{kind: 1, created_at: 1_000_000})
      event_fixture(%{kind: 7, created_at: 2_000_000})

      assert Notes.max_created_at(kinds: [1]) == 1_000_000
    end

    test "respects :authors filter" do
      pk1 = unique_pubkey()
      pk2 = unique_pubkey()

      event_fixture(%{pubkey: pk1, created_at: 1_000_000})
      event_fixture(%{pubkey: pk2, created_at: 2_000_000})

      assert Notes.max_created_at(authors: [pk1]) == 1_000_000
    end
  end

  describe "since_for_filter/1" do
    test "falls back to now minus window when no events exist" do
      result = Notes.since_for_filter()
      now = System.os_time(:second)
      assert_in_delta result, now - 86_400, 5
    end

    test "returns max_created_at when events exist" do
      event_fixture(%{created_at: 1_700_000_000})
      assert Notes.since_for_filter() == 1_700_000_000
    end
  end
end
