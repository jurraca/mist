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

  describe "backfill_profiles/2" do
    test "marks nothing as fetched when sends fail (no relays connected)" do
      me = profile_fixture()
      f1 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)

      state = %SubManager{identity: me.pubkey}
      desired = SubManager.desired_feeds(me.pubkey)

      new_state = SubManager.backfill_profiles(state, desired)

      assert MapSet.size(new_state.profiles_fetched) == 0
    end

    test "skips pubkeys already fetched" do
      me = profile_fixture()
      f1 = profile_fixture()
      follows_fixture(me.pubkey, f1.pubkey)

      desired = SubManager.desired_feeds(me.pubkey)
      state = %SubManager{profiles_fetched: MapSet.new([f1.pubkey])}

      assert SubManager.backfill_profiles(state, desired) == state
    end

    test "already-fetched pubkeys stay fetched across identity switches" do
      state = %SubManager{profiles_fetched: MapSet.new(["pk1"])}

      assert {:noreply, new_state} =
               SubManager.handle_cast({:identity_switched, unique_pubkey(), nil}, state)

      assert MapSet.member?(new_state.profiles_fetched, "pk1")
    end
  end

  describe "profile sub TTL close" do
    test "close_profile_sub untracks the sub and clears the listener registration" do
      sub_id = unique_event_id()
      {:ok, _} = Registry.register(NostrEx.PubSub, sub_id, [])

      state = %SubManager{profile_subs: MapSet.new([sub_id])}

      assert {:noreply, new_state} = SubManager.handle_info({:close_profile_sub, sub_id}, state)

      assert MapSet.size(new_state.profile_subs) == 0
      assert Registry.lookup(NostrEx.PubSub, sub_id) == []
    end

    test "close_profile_sub for an unknown sub is a no-op" do
      state = %SubManager{}

      assert {:noreply, ^state} = SubManager.handle_info({:close_profile_sub, "unknown"}, state)
    end

    test "identity switch closes tracked profile subs" do
      sub_id = unique_event_id()
      {:ok, _} = Registry.register(NostrEx.PubSub, sub_id, [])

      state = %SubManager{
        profiles_fetched: MapSet.new(["pk1"]),
        profile_subs: MapSet.new([sub_id])
      }

      assert {:noreply, new_state} =
               SubManager.handle_cast({:identity_switched, unique_pubkey(), nil}, state)

      assert MapSet.size(new_state.profile_subs) == 0
      assert Registry.lookup(NostrEx.PubSub, sub_id) == []
      assert MapSet.member?(new_state.profiles_fetched, "pk1")
    end
  end

  describe "reroute_blacklisted/2" do
    test "reroutes follows from a blacklisted write relay to usable fallbacks" do
      state = %SubManager{
        relay_health: %{"dead-write.test" => %{failures: 3, blackout_until: System.os_time(:second) + 300}}
      }

      desired = %{"wss://dead-write.test" => MapSet.new(["pk1"])}

      result = SubManager.reroute_blacklisted(state, desired)

      refute Map.has_key?(result, "wss://dead-write.test")
      for fb <- @fallback do
        assert MapSet.equal?(result[fb], MapSet.new(["pk1"]))
      end
    end

    test "keeps non-blacklisted relays in place" do
      state = %SubManager{}
      desired = %{"wss://alive-write.test" => MapSet.new(["pk1"])}

      assert SubManager.reroute_blacklisted(state, desired) == desired
    end

    test "unions rerouted pubkeys onto fallbacks that already have follows" do
      state = %SubManager{
        relay_health: %{"dead-write.test" => %{failures: 1, blackout_until: System.os_time(:second) + 30}}
      }

      desired = %{
        "wss://dead-write.test" => MapSet.new(["pk1"]),
        @fallback |> hd() => MapSet.new(["pk2"])
      }

      result = SubManager.reroute_blacklisted(state, desired)

      refute Map.has_key?(result, "wss://dead-write.test")
      assert MapSet.equal?(result[@fallback |> hd()], MapSet.new(["pk1", "pk2"]))
    end

    test "drops rerouted pubkeys when all fallbacks are blacklisted" do
      now = System.os_time(:second)

      state = %SubManager{
        relay_health:
          Map.new(@fallback, fn fb -> {Mist.Relay.relay_name(fb), %{failures: 1, blackout_until: now + 30}} end)
          |> Map.put("dead-write.test", %{failures: 1, blackout_until: now + 30})
      }

      desired = %{"wss://dead-write.test" => MapSet.new(["pk1"])}

      assert SubManager.reroute_blacklisted(state, desired) == %{}
    end
  end

  describe "relay health recording" do
    test "record_relay_failures sets blackout with backoff" do
      state = %SubManager{}
      now = System.os_time(:second)

      state = SubManager.record_relay_failures(state, ["wss://dead.test"])

      health = state.relay_health["dead.test"]
      assert health.failures == 1
      assert health.blackout_until > now
      assert health.blackout_until <= now + 300
    end

    test "repeated failures increase backoff" do
      state = %SubManager{}
      one = SubManager.record_relay_failures(state, ["wss://dead.test"])
      two = SubManager.record_relay_failures(one, ["wss://dead.test"])

      assert two.relay_health["dead.test"].failures == 2
      assert two.relay_health["dead.test"].blackout_until > one.relay_health["dead.test"].blackout_until
    end

    test "permanent blacklist after threshold failures" do
      state = %SubManager{}

      state =
        ["wss://dead.test", "wss://dead.test", "wss://dead.test"]
        |> Enum.reduce(state, &SubManager.record_relay_failures(&2, [&1]))

      assert state.relay_health["dead.test"].permanent == true
    end

    test "clear_relay_failures removes health for connected relays" do
      state = %SubManager{relay_health: %{"back.test" => %{failures: 2, blackout_until: 0}}}

      state = SubManager.clear_relay_failures(state, ["wss://back.test"])

      assert state.relay_health == %{}
    end
  end

  describe "permanent_blacklist/2" do
    test "marks a relay permanently blacklisted by host" do
      state = %SubManager{}
      state = SubManager.permanent_blacklist(state, "auth.relay.test")

      assert state.relay_health["auth.relay.test"].permanent == true
    end

    test "accepts full URLs and normalizes to host" do
      state = %SubManager{}
      state = SubManager.permanent_blacklist(state, "wss://auth.relay.test")

      assert state.relay_health["auth.relay.test"].permanent == true
    end

    test "is idempotent" do
      state = %SubManager{}
      one = SubManager.permanent_blacklist(state, "auth.relay.test")
      two = SubManager.permanent_blacklist(one, "auth.relay.test")

      assert one.relay_health == two.relay_health
    end
  end

  describe "handle_info({:close, ..., message})" do
    test "auth-required close permanently blacklists the relay" do
      state = %SubManager{
        feed: %{"wss://auth.relay.test" => %{"sub-1" => MapSet.new(["pk1"])}}
      }

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:close, "sub-1", "auth.relay.test", "auth-required: please authenticate before sending REQs"},
                 state
               )

      assert new_state.relay_health["auth.relay.test"].permanent == true
    end

    test "rate-limited close permanently blacklists the relay" do
      state = %SubManager{
        feed: %{"wss://rate.relay.test" => %{"sub-1" => MapSet.new(["pk1"])}}
      }

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:close, "sub-1", "rate.relay.test", "rate-limited: too many subscriptions"},
                 state
               )

      assert new_state.relay_health["rate.relay.test"].permanent == true
    end

    test "non-auth/non-rate close does not blacklist" do
      state = %SubManager{
        feed: %{"wss://normal.relay.test" => %{"sub-1" => MapSet.new(["pk1"])}}
      }

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:close, "sub-1", "normal.relay.test", "invalid filter"},
                 state
               )

      assert new_state.relay_health == %{}
    end
  end

  describe "handle_info({:notice, ...})" do
    test "auth-required notice permanently blacklists the relay" do
      state = %SubManager{}

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:notice, "sub-1", "nostr.wine", "auth-required: please authenticate before sending REQs"},
                 state
               )

      assert new_state.relay_health["nostr.wine"].permanent == true
    end

    test "NIP-42 auth notice with challenge blacklists the relay" do
      state = %SubManager{}

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:notice, "sub-1", "nostrrelay.com", "auth required: NIP-42 AUTH not received in time"},
                 state
               )

      assert new_state.relay_health["nostrrelay.com"].permanent == true
    end

    test "non-auth notice does not blacklist" do
      state = %SubManager{}

      assert {:noreply, new_state} =
               SubManager.handle_info(
                 {:notice, "sub-1", "some.relay.test", "rate limit exceeded for this IP"},
                 state
               )

      assert new_state.relay_health == %{}
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
