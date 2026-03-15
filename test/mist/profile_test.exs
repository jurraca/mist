defmodule Mist.ProfileTest do
  use Mist.DataCase

  alias Mist.Profile
  alias Mist.Profile.Profile, as: ProfileSchema

  import Mist.NostrFixtures

  describe "basic CRUD" do
    test "list_profiles/0 returns all profiles" do
      profile = profile_fixture()
      assert Profile.list_profiles() == [profile]
    end

    test "get_profile!/1 returns the profile with given id" do
      profile = profile_fixture()
      assert Profile.get_profile!(profile.id) == profile
    end

    test "create_profile/1 with valid pubkey creates a profile" do
      pubkey = unique_pubkey()
      assert {:ok, %ProfileSchema{} = profile} = Profile.create_profile(%{pubkey: pubkey})
      assert profile.pubkey == pubkey
    end

    test "create_profile/1 without pubkey returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Profile.create_profile(%{})
    end

    test "create_profile/1 with short pubkey returns error changeset" do
      assert {:error, changeset} = Profile.create_profile(%{pubkey: "tooshort"})
      assert %{pubkey: _} = errors_on(changeset)
    end

    test "update_profile/2 with valid data updates the profile" do
      profile = profile_fixture()
      assert {:ok, %ProfileSchema{} = updated} = Profile.update_profile(profile, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "delete_profile/1 deletes the profile" do
      profile = profile_fixture()
      assert {:ok, %ProfileSchema{}} = Profile.delete_profile(profile)
      assert_raise Ecto.NoResultsError, fn -> Profile.get_profile!(profile.id) end
    end

    test "change_profile/1 returns a profile changeset" do
      profile = profile_fixture()
      assert %Ecto.Changeset{} = Profile.change_profile(profile)
    end
  end

  describe "pubkey lookup" do
    test "get_by_pubkey/1 returns profile when found" do
      profile = profile_fixture()
      assert {:ok, found} = Profile.get_by_pubkey(profile.pubkey)
      assert found.id == profile.id
    end

    test "get_by_pubkey/1 returns error when not found" do
      assert {:error, :not_found} = Profile.get_by_pubkey(unique_pubkey())
    end
  end

  describe "get_or_create_profile/1" do
    test "creates profile on first call" do
      pubkey = unique_pubkey()
      assert {:ok, profile} = Profile.get_or_create_profile(pubkey)
      assert profile.pubkey == pubkey
    end

    test "returns existing profile on second call (idempotent)" do
      pubkey = unique_pubkey()
      {:ok, first} = Profile.get_or_create_profile(pubkey)
      {:ok, second} = Profile.get_or_create_profile(pubkey)
      assert first.id == second.id
    end

    test "accepts map with string key" do
      pubkey = unique_pubkey()
      {:ok, profile} = Profile.get_or_create_profile(%{"pubkey" => pubkey})
      assert profile.pubkey == pubkey
    end
  end

  describe "create_or_update_profile/1" do
    test "creates profile when not found" do
      pubkey = unique_pubkey()
      assert {:ok, profile} = Profile.create_or_update_profile(%{"pubkey" => pubkey, "name" => "New"})
      assert profile.name == "New"
    end

    test "updates profile when found" do
      pubkey = unique_pubkey()
      {:ok, _} = Profile.create_or_update_profile(%{"pubkey" => pubkey, "name" => "Old"})
      {:ok, updated} = Profile.create_or_update_profile(%{"pubkey" => pubkey, "name" => "Updated"})
      assert updated.name == "Updated"
    end
  end

  describe "follow management" do
    test "follow_profile/2 creates a follow relationship" do
      follower = profile_fixture()
      followed = profile_fixture()
      assert {:ok, follow} = Profile.follow_profile(follower.pubkey, followed.pubkey)
      assert follow.follower_id == follower.id
      assert follow.followed_id == followed.id
    end

    test "unfollow_profile/2 removes a follow relationship" do
      follower = profile_fixture()
      followed = profile_fixture()
      {:ok, _} = Profile.follow_profile(follower.pubkey, followed.pubkey)
      assert {1, _} = Profile.unfollow_profile(follower.pubkey, followed.pubkey)
    end

    test "unfollow_profile/2 when no follow exists returns 0 deleted" do
      follower = profile_fixture()
      followed = profile_fixture()
      assert {0, _} = Profile.unfollow_profile(follower.pubkey, followed.pubkey)
    end
  end

  describe "follow visibility" do
    test "get_public_follows/1 returns only public follows" do
      follower = profile_fixture()
      pub = profile_fixture()
      priv = profile_fixture()

      {:ok, f1} = Profile.follow_profile(follower.pubkey, pub.pubkey)
      {:ok, f2} = Profile.follow_profile(follower.pubkey, priv.pubkey)

      Profile.toggle_follow_visibility(f1.id, true)

      public_follows = Profile.get_public_follows(follower.id)
      assert length(public_follows) == 1
      assert hd(public_follows).id == pub.id
    end

    test "get_private_follows/1 returns only private follows" do
      follower = profile_fixture()
      pub = profile_fixture()
      priv = profile_fixture()

      {:ok, f1} = Profile.follow_profile(follower.pubkey, pub.pubkey)
      {:ok, f2} = Profile.follow_profile(follower.pubkey, priv.pubkey)

      Profile.toggle_follow_visibility(f1.id, true)

      private_follows = Profile.get_private_follows(follower.id)
      assert length(private_follows) == 1
      assert hd(private_follows).id == priv.id
    end

    test "get_follows_with_privacy/1 returns all follows with privacy info" do
      follower = profile_fixture()
      followed = profile_fixture()

      {:ok, follow} = Profile.follow_profile(follower.pubkey, followed.pubkey)

      results = Profile.get_follows_with_privacy(follower.id)
      assert length(results) == 1
      assert hd(results).follow_id == follow.id
    end

    test "toggle_follow_visibility/2 changes visibility" do
      follower = profile_fixture()
      followed = profile_fixture()

      {:ok, follow} = Profile.follow_profile(follower.pubkey, followed.pubkey)

      assert {1, _} = Profile.toggle_follow_visibility(follow.id, true)

      public_follows = Profile.get_public_follows(follower.id)
      assert length(public_follows) == 1
    end
  end

  describe "follow list management" do
    setup do
      profile = profile_fixture()
      {:ok, profile: profile}
    end

    test "create_follow_list/2 creates a list", %{profile: profile} do
      assert {:ok, list} = Profile.create_follow_list(profile.id, %{name: "My List"})
      assert list.name == "My List"
      assert list.profile_id == profile.id
    end

    test "create_follow_list/2 requires name", %{profile: profile} do
      assert {:error, changeset} = Profile.create_follow_list(profile.id, %{})
      assert %{name: _} = errors_on(changeset)
    end

    test "update_follow_list/2 updates a list", %{profile: profile} do
      list = follow_list_fixture(profile.id)
      assert {:ok, updated} = Profile.update_follow_list(list.id, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "update_follow_list/2 returns error for missing list" do
      assert {:error, :not_found} = Profile.update_follow_list(-1, %{name: "X"})
    end

    test "delete_follow_list/1 deletes a list", %{profile: profile} do
      list = follow_list_fixture(profile.id)
      assert {:ok, _} = Profile.delete_follow_list(list.id)
      assert {:error, :not_found} = Profile.delete_follow_list(list.id)
    end

    test "delete_follow_list/1 returns error for missing list" do
      assert {:error, :not_found} = Profile.delete_follow_list(-1)
    end

    test "get_follow_lists/1 returns all lists for profile", %{profile: profile} do
      follow_list_fixture(profile.id, %{name: "Alpha"})
      follow_list_fixture(profile.id, %{name: "Beta"})
      lists = Profile.get_follow_lists(profile.id)
      assert length(lists) == 2
      assert Enum.map(lists, & &1.name) == ["Alpha", "Beta"]
    end

    test "add_follow_to_list and remove_follow_from_list", %{profile: profile} do
      followed = profile_fixture()
      {:ok, follow} = Profile.follow_profile(profile.pubkey, followed.pubkey)
      list = follow_list_fixture(profile.id)

      assert {:ok, _} = Profile.add_follow_to_list(follow.id, list.id)

      follows_in_list = Profile.get_follows_in_list(list.id)
      assert length(follows_in_list) == 1

      assert {1, _} = Profile.remove_follow_from_list(follow.id, list.id)
      assert Profile.get_follows_in_list(list.id) == []
    end

    test "get_pubkeys_in_list/1 returns pubkeys", %{profile: profile} do
      followed = profile_fixture()
      {:ok, follow} = Profile.follow_profile(profile.pubkey, followed.pubkey)
      list = follow_list_fixture(profile.id)
      Profile.add_follow_to_list(follow.id, list.id)

      pubkeys = Profile.get_pubkeys_in_list(list.id)
      assert followed.pubkey in pubkeys
    end

    test "get_lists_for_follow/1 returns lists a follow belongs to", %{profile: profile} do
      followed = profile_fixture()
      {:ok, follow} = Profile.follow_profile(profile.pubkey, followed.pubkey)
      list = follow_list_fixture(profile.id)
      Profile.add_follow_to_list(follow.id, list.id)

      lists = Profile.get_lists_for_follow(follow.id)
      assert length(lists) == 1
      assert hd(lists).id == list.id
    end

    test "get_list_with_count/1 returns list with member count", %{profile: profile} do
      followed = profile_fixture()
      {:ok, follow} = Profile.follow_profile(profile.pubkey, followed.pubkey)
      list = follow_list_fixture(profile.id)
      Profile.add_follow_to_list(follow.id, list.id)

      assert {:ok, result} = Profile.get_list_with_count(list.id)
      assert result.member_count == 1
    end

    test "get_list_with_count/1 returns error for missing list" do
      assert {:error, :not_found} = Profile.get_list_with_count(-1)
    end
  end

  describe "user relay management" do
    test "add_user_relays/2 creates user relays via parse_tag" do
      pubkey = unique_pubkey()
      profile_fixture(%{pubkey: pubkey})
      relay = relay_fixture(%{"url" => "wss://user-relay.example.com"})

      tags = [%{data: "wss://user-relay.example.com", info: ["read"]}]
      assert {count, _} = Profile.add_user_relays(pubkey, tags)
      assert count >= 1
    end

    test "add_user_relays/2 returns error for unknown profile" do
      assert {:error, :profile_not_found} = Profile.add_user_relays(unique_pubkey(), [])
    end

    test "add_user_relays/2 translates purpose correctly" do
      pubkey = unique_pubkey()
      profile_fixture(%{pubkey: pubkey})

      tags = [
        %{data: "wss://read-relay.example.com", info: ["read"]},
        %{data: "wss://write-relay.example.com", info: ["write"]},
        %{data: "wss://rw-relay.example.com", info: []}
      ]

      Profile.add_user_relays(pubkey, tags)

      relays = Profile.get_user_relays(pubkey)
      purposes = Enum.map(relays, & &1.purpose) |> Enum.sort()
      assert :r in purposes
      assert :w in purposes
      assert :rw in purposes
    end
  end

  describe "relay discovery queries" do
    test "fetch_profiles_without_relays/0 returns profiles with no relays" do
      profile = profile_fixture(%{relay: nil})
      result = Profile.fetch_profiles_without_relays()
      assert Enum.any?(result, fn p -> p.id == profile.id end)
    end

    test "fetch_profiles_without_relays/0 excludes profiles with relay field set" do
      profile = profile_fixture(%{relay: "wss://some-relay.com"})
      result = Profile.fetch_profiles_without_relays()
      refute Enum.any?(result, fn p -> p.id == profile.id end)
    end

    test "fetch_pubkeys_without_relays/1 returns matching pubkeys" do
      p1 = profile_fixture(%{relay: nil})
      p2 = profile_fixture(%{relay: "wss://has-relay.com"})

      result = Profile.fetch_pubkeys_without_relays([p1.pubkey, p2.pubkey])
      assert p1.pubkey in result
      refute p2.pubkey in result
    end

    test "fetch_profiles_for_relay_discovery/1 returns unchecked profiles" do
      profile = profile_fixture()
      result = Profile.fetch_profiles_for_relay_discovery(10)
      assert Enum.any?(result, fn p -> p.id == profile.id end)
    end

    test "fetch_profiles_for_relay_discovery/1 excludes recently checked profiles" do
      profile = profile_fixture()
      Profile.update_relay_check_timestamp(profile.pubkey)

      result = Profile.fetch_profiles_for_relay_discovery(10)
      refute Enum.any?(result, fn p -> p.id == profile.id end)
    end

    test "update_relay_check_timestamp/1 sets relay_last_checked" do
      profile = profile_fixture()
      assert {1, _} = Profile.update_relay_check_timestamp(profile.pubkey)

      updated = Profile.get_profile!(profile.id)
      assert updated.relay_last_checked != nil
    end

    test "get_write_relays_by_relay/1 groups write relays by URL" do
      pubkey = unique_pubkey()
      profile = profile_fixture(%{pubkey: pubkey})
      relay = relay_fixture(%{"url" => "wss://write-relay.example.com"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        Mist.Profile.UserRelays,
        [%{relay_id: relay.id, pubkey: pubkey, profile_id: profile.id, purpose: :w, inserted_at: now, updated_at: now}],
        on_conflict: :nothing
      )

      result = Profile.get_write_relays_by_relay([profile])
      assert Map.has_key?(result, "wss://write-relay.example.com")
      assert pubkey in result["wss://write-relay.example.com"]
    end
  end
end
