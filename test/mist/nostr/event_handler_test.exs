defmodule Mist.Nostr.EventHandlerTest do
  use Mist.DataCase, async: true

  import Mist.NostrFixtures

  alias Mist.Nostr.EventHandler

  defp broadcast_events do
    {:ok, pid} = Task.start(fn -> receive do: (:stop -> :ok) end)
    {:ok, _} = Registry.register(Mist.PubSub, "notes", [])
    {:ok, _} = Registry.register(Mist.PubSub, "note_counts", [])
    pid
  end

  defp drain_broadcasts(timeout \\ 50) do
    receive do
      msg -> [msg | drain_broadcasts(timeout)]
    after
      timeout -> []
    end
  end

  defp kind_1_event(id, pubkey) do
    %NostrCore.Event{
      id: id,
      pubkey: pubkey,
      kind: 1,
      content: "hello",
      created_at: DateTime.utc_now(),
      tags: [],
      sig: unique_sig()
    }
  end

  defp kind_7_event(id, pubkey, note_id) do
    %NostrCore.Event{
      id: id,
      pubkey: pubkey,
      kind: 7,
      content: "+",
      created_at: DateTime.utc_now(),
      tags: [%NostrCore.Tag{type: "e", data: note_id, info: []}],
      sig: unique_sig()
    }
  end

  describe "duplicate suppression" do
    test "kind-1: only the first copy broadcasts on notes" do
      broadcaster = broadcast_events()

      event = kind_1_event(unique_event_id(), unique_pubkey())
      :ok = EventHandler.process_event(event)
      :ok = EventHandler.process_event(event)
      :ok = EventHandler.process_event(event)

      broadcasts = drain_broadcasts()
      notes = Enum.filter(broadcasts, &match?(%{kind: 1}, &1))
      assert length(notes) == 1

      send(broadcaster, :stop)
    end

    test "kind-7: only the first copy broadcasts a count update" do
      broadcaster = broadcast_events()

      note = event_fixture()
      reaction = kind_7_event(unique_event_id(), unique_pubkey(), note.event_id)
      :ok = EventHandler.process_event(reaction)
      :ok = EventHandler.process_event(reaction)

      broadcasts = drain_broadcasts()
      counts = Enum.filter(broadcasts, &match?(%{note_id: _, counts: _}, &1))
      assert length(counts) == 1
      assert %{counts: %{reaction_count: 1}} = hd(counts)

      send(broadcaster, :stop)
    end

    test "distinct kind-1 events both broadcast" do
      broadcaster = broadcast_events()

      :ok = EventHandler.process_event(kind_1_event(unique_event_id(), unique_pubkey()))
      :ok = EventHandler.process_event(kind_1_event(unique_event_id(), unique_pubkey()))

      broadcasts = drain_broadcasts()
      notes = Enum.filter(broadcasts, &match?(%{kind: 1}, &1))
      assert length(notes) == 2

      send(broadcaster, :stop)
    end
  end
end
