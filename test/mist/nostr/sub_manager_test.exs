defmodule Mist.Nostr.SubManagerTest do
  use Mist.DataCase, async: true

  import Mist.NostrFixtures

  alias Mist.Nostr.SubManager

  @fallback ["wss://fallback-a.test", "wss://fallback-b.test"]

  setup do
    previous = Application.get_env(:mist, :fallback_relays)
    Application.put_env(:mist, :fallback_relays, @fallback)

    on_exit(fn ->
      if previous do
        Application.put_env(:mist, :fallback_relays, previous)
      else
        Application.delete_env(:mist, :fallback_relays)
      end
    end)

    :ok
  end

  describe "desired_feeds/1" do
    test "returns empty map when identity has no profile" do
      assert SubManager.desired_feeds(unique_pubkey()) == %{}
    end

    test "returns empty map when identity follows nobody" do
      me = profile_fixture()
      assert SubManager.desired_feeds(me.pubkey) == %{}
    end

    test "groups follows by their write relays" do
      me = profile_fixture()
      f1 = profile_fixture()
      f2 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)
      follows_fixture(me.pubkey, f2.pubkey)
      user_relay_fixture(f1.pubkey, "wss://f1-writes.test")
      user_relay_fixture(f1.pubkey, "wss://shared.test")
      user_relay_fixture(f2.pubkey, "wss://shared.test")

      desired = SubManager.desired_feeds(me.pubkey)

      assert MapSet.equal?(desired["wss://f1-writes.test"], MapSet.new([f1.pubkey]))
      assert MapSet.equal?(desired["wss://shared.test"], MapSet.new([f1.pubkey, f2.pubkey]))
      refute Map.has_key?(desired, "wss://fallback-a.test")
    end

    test "follows without known write relays go to the fallback relays" do
      me = profile_fixture()
      f1 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)

      desired = SubManager.desired_feeds(me.pubkey)

      for relay <- @fallback do
        assert MapSet.equal?(desired[relay], MapSet.new([f1.pubkey]))
      end
    end

    test "read-only relays do not count as write relays" do
      me = profile_fixture()
      f1 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)
      user_relay_fixture(f1.pubkey, "wss://readonly.test", :r)

      desired = SubManager.desired_feeds(me.pubkey)

      refute Map.has_key?(desired, "wss://readonly.test")
      assert MapSet.member?(desired["wss://fallback-a.test"], f1.pubkey)
    end

    test "invalid relay urls are dropped and their pubkeys fall back" do
      me = profile_fixture()
      f1 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)
      user_relay_fixture(f1.pubkey, "not-a-relay-url")

      desired = SubManager.desired_feeds(me.pubkey)

      refute Map.has_key?(desired, "not-a-relay-url")
      assert MapSet.member?(desired["wss://fallback-a.test"], f1.pubkey)
    end

    test "mix of covered and uncovered follows" do
      me = profile_fixture()
      covered = profile_fixture()
      uncovered = profile_fixture()
      follows_fixture(me.pubkey, covered.pubkey)
      follows_fixture(me.pubkey, uncovered.pubkey)
      user_relay_fixture(covered.pubkey, "wss://covered.test")

      desired = SubManager.desired_feeds(me.pubkey)

      assert MapSet.equal?(desired["wss://covered.test"], MapSet.new([covered.pubkey]))

      for relay <- @fallback do
        assert MapSet.equal?(desired[relay], MapSet.new([uncovered.pubkey]))
      end
    end
  end

  describe "handle_cast({:subscribe, ...})" do
    test "invalid filters do not crash and leave state unchanged" do
      state = %SubManager{}

      assert {:noreply, ^state} =
               SubManager.handle_cast({:subscribe, [kinds: ["nope"]], []}, state)
    end

    test "failed sends are not stored as named subscriptions" do
      state = %SubManager{}

      # no relays connected in test env, so the send fails
      assert {:noreply, new_state} =
               SubManager.handle_cast({:subscribe_named, :notes_feed, [kinds: [1]], []}, state)

      assert new_state.named == %{}
    end
  end

  describe "handle_info({:close, ...})" do
    test "evicts the sub from feed state, matching relay by host" do
      state = %SubManager{
        feed: %{
          "wss://nos.lol" => %{"sub-1" => MapSet.new(["pk1"])},
          "wss://relay.damus.io" => %{"sub-2" => MapSet.new(["pk2"])}
        }
      }

      assert {:noreply, new_state} = SubManager.handle_info({:close, "sub-1", "nos.lol"}, state)

      refute Map.has_key?(new_state.feed, "wss://nos.lol")
      assert Map.has_key?(new_state.feed["wss://relay.damus.io"], "sub-2")
    end

    test "keeps the relay entry when other subs remain on it" do
      state = %SubManager{
        feed: %{"wss://nos.lol" => %{"sub-1" => MapSet.new(["pk1"]), "sub-2" => MapSet.new(["pk2"])}}
      }

      assert {:noreply, new_state} = SubManager.handle_info({:close, "sub-1", "nos.lol"}, state)

      assert Map.keys(new_state.feed["wss://nos.lol"]) == ["sub-2"]
    end

    test "evicts named subs by sub_id" do
      state = %SubManager{named: %{notes_feed: "sub-9", other: "sub-8"}}

      assert {:noreply, new_state} = SubManager.handle_info({:close, "sub-9", "nos.lol"}, state)

      assert new_state.named == %{other: "sub-8"}
    end

    test "unknown sub leaves state unchanged" do
      state = %SubManager{feed: %{}, named: %{}}

      assert {:noreply, ^state} = SubManager.handle_info({:close, "nope", "nos.lol"}, state)
    end

    test "closing the meta sub clears it so reconcile reopens it" do
      state = %SubManager{meta_sub: "meta-1", identity: unique_pubkey()}

      assert {:noreply, new_state} = SubManager.handle_info({:close, "meta-1", "purplepag.es"}, state)

      assert new_state.meta_sub == nil
    end

    test "closing an unrelated sub keeps the meta sub" do
      state = %SubManager{meta_sub: "meta-1", identity: unique_pubkey()}

      assert {:noreply, new_state} = SubManager.handle_info({:close, "other", "nos.lol"}, state)

      assert new_state.meta_sub == "meta-1"
    end
  end

  describe "handle_cast({:identity_switched, ...})" do
    test "resets subs, sets identity and relay hint, schedules reconcile" do
      state = %SubManager{
        identity: unique_pubkey(),
        meta_sub: "meta-1",
        meta_relay_hint: nil,
        feed: %{"wss://nos.lol" => %{"sub-1" => MapSet.new(["pk"])}},
        named: %{notes_feed: "sub-9"}
      }

      new_pk = unique_pubkey()

      assert {:noreply, new_state} =
               SubManager.handle_cast({:identity_switched, new_pk, "wss://hint.test"}, state)

      assert new_state.identity == new_pk
      assert new_state.meta_relay_hint == "wss://hint.test"
      assert new_state.feed == %{}
      assert new_state.meta_sub == nil
      # named subs belong to the UI and survive identity switches
      assert new_state.named == %{notes_feed: "sub-9"}
      assert new_state.reconcile_timer != nil
    end
  end
end
