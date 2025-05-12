defmodule Mist.NostrTest do
  use Mist.DataCase

  alias Mist.Nostr

  describe "relays" do
    alias Mist.Relay

    import Mist.NostrFixtures

    @invalid_attrs %{name: nil, version: nil, description: nil, banner: nil, icon: nil, pubkey: nil, contact: nil, supported_nips: nil, software: nil}

    test "list_relays/0 returns all relays" do
      relay = relay_fixture()
      assert Relay.list_relays() == [relay]
    end

    test "get_relay!/1 returns the relay with given id" do
      relay = relay_fixture()
      assert Relay.get_relay!(relay.id) == relay
    end

    test "create_relay/1 with valid data creates a relay" do
      valid_attrs = %{name: "some name", version: "some version", description: "some description", banner: "some banner", icon: "some icon", pubkey: "some pubkey", contact: "some contact", supported_nips: [1, 2], software: "some software"}

      assert {:ok, %Relay{} = relay} = Nostr.create_relay(valid_attrs)
      assert relay.name == "some name"
      assert relay.version == "some version"
      assert relay.description == "some description"
      assert relay.banner == "some banner"
      assert relay.icon == "some icon"
      assert relay.pubkey == "some pubkey"
      assert relay.contact == "some contact"
      assert relay.supported_nips == [1, 2]
      assert relay.software == "some software"
    end

    test "create_relay/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Nostr.create_relay(@invalid_attrs)
    end

    test "update_relay/2 with valid data updates the relay" do
      relay = relay_fixture()
      update_attrs = %{name: "some updated name", version: "some updated version", description: "some updated description", banner: "some updated banner", icon: "some updated icon", pubkey: "some updated pubkey", contact: "some updated contact", supported_nips: [1], software: "some updated software"}

      assert {:ok, %Relay.Relay{} = relay} = Relay.update_relay(relay, update_attrs)
      assert relay.name == "some updated name"
      assert relay.version == "some updated version"
      assert relay.description == "some updated description"
      assert relay.banner == "some updated banner"
      assert relay.icon == "some updated icon"
      assert relay.pubkey == "some updated pubkey"
      assert relay.contact == "some updated contact"
      assert relay.supported_nips == [1]
      assert relay.software == "some updated software"
    end

    test "update_relay/2 with invalid data returns error changeset" do
      relay = relay_fixture()
      assert {:error, %Ecto.Changeset{}} = Relay.update_relay(relay, @invalid_attrs)
      assert relay == Relay.get_relay!(relay.id)
    end

    test "delete_relay/1 deletes the relay" do
      relay = relay_fixture()
      assert {:ok, %Relay.Relay{}} = Relay.delete_relay(relay)
      assert_raise Ecto.NoResultsError, fn -> Nostr.get_relay!(relay.id) end
    end

    test "change_relay/1 returns a relay changeset" do
      relay = relay_fixture()
      assert %Ecto.Changeset{} = Relay.change_relay(relay)
    end
  end

  describe "profiles" do
    alias Mist.Profile

    import Mist.NostrFixtures

    @invalid_attrs %{}

    test "list_profiles/0 returns all profiles" do
      profile = profile_fixture()
      assert Profile.list_profiles() == [profile]
    end

    test "get_profile!/1 returns the profile with given id" do
      profile = profile_fixture()
      assert Profile.get_profile!(profile.id) == profile
    end

    test "create_profile/1 with valid data creates a profile" do
      valid_attrs = %{}

      assert {:ok, %Profile.Profile{} = profile} = Nostr.create_profile(valid_attrs)
    end

    test "create_profile/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Profile.create_profile(@invalid_attrs)
    end

    test "update_profile/2 with valid data updates the profile" do
      profile = profile_fixture()
      update_attrs = %{}

      assert {:ok, %Profile{} = profile} = Profile.update_profile(profile, update_attrs)
    end

    test "update_profile/2 with invalid data returns error changeset" do
      profile = profile_fixture()
      assert {:error, %Ecto.Changeset{}} = Profile.update_profile(profile, @invalid_attrs)
      assert profile == Profile.get_profile!(profile.id)
    end

    test "delete_profile/1 deletes the profile" do
      profile = profile_fixture()
      assert {:ok, %Profile{}} = Profile.delete_profile(profile)
      assert_raise Ecto.NoResultsError, fn -> Profile.get_profile!(profile.id) end
    end

    test "change_profile/1 returns a profile changeset" do
      profile = profile_fixture()
      assert %Ecto.Changeset{} = Profile.change_profile(profile)
    end
  end
end
