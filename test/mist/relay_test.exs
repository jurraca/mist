defmodule Mist.RelayTest do
  use Mist.DataCase

  alias Mist.Relay
  alias Mist.Relay.Info, as: RelaySchema

  import Mist.NostrFixtures

  describe "CRUD" do
    test "list_relays/0 returns all relays" do
      relay = relay_fixture()
      assert Relay.list_relays() == [relay]
    end

    test "get_relay!/1 returns the relay with given id" do
      relay = relay_fixture()
      assert Relay.get_relay!(relay.id) == relay
    end

    test "create_relay/1 with valid data creates a relay" do
      attrs = %{
        "url" => "wss://relay.example.com",
        "version" => "1.0",
        "description" => "A test relay",
        "contact" => "admin@example.com",
        "supported_nips" => [1, 2],
        "software" => "test-software"
      }

      assert {:ok, %RelaySchema{} = relay} = Relay.create_relay(attrs)
      assert relay.url == "wss://relay.example.com"
      assert relay.version == "1.0"
      assert relay.description == "A test relay"
      assert relay.contact == "admin@example.com"
      assert relay.supported_nips == [1, 2]
      assert relay.software == "test-software"
    end

    test "create_relay/1 without url raises" do
      assert_raise FunctionClauseError, fn -> Relay.create_relay(%{name: "no url"}) end
    end

    test "update_relay/2 with valid data updates the relay" do
      relay = relay_fixture()

      update_attrs = %{
        "url" => "wss://updated.example.com",
        "version" => "2.0",
        "description" => "updated"
      }

      assert {:ok, %RelaySchema{} = updated} = Relay.update_relay(relay, update_attrs)
      assert updated.version == "2.0"
      assert updated.description == "updated"
    end

    test "delete_relay/1 deletes the relay" do
      relay = relay_fixture()
      assert {:ok, %RelaySchema{}} = Relay.delete_relay(relay)
      assert_raise Ecto.NoResultsError, fn -> Relay.get_relay!(relay.id) end
    end

    test "change_relay/2 with url returns a changeset" do
      relay = relay_fixture()
      assert %Ecto.Changeset{} = Relay.change_relay(relay, %{"url" => "wss://changed.example.com"})
    end
  end

  describe "changeset behaviour" do
    test "extracts name from URL host" do
      {:ok, relay} = Relay.create_relay(%{"url" => "wss://nostr.example.com"})
      assert relay.name == "nostr.example.com"
    end

    test "normalises trailing slashes" do
      {:ok, relay} = Relay.create_relay(%{"url" => "wss://relay.example.com/"})
      refute String.ends_with?(relay.url, "/")
    end

    test "url unique constraint" do
      relay_fixture(%{"url" => "wss://unique-relay.example.com"})
      assert {:error, changeset} = Relay.create_relay(%{"url" => "wss://unique-relay.example.com"})
      assert %{url: _} = errors_on(changeset)
    end
  end

  describe "get_or_create_relay/2" do
    test "creates on first call" do
      assert {:ok, %RelaySchema{} = relay} = Relay.get_or_create_relay("wss://new-relay.example.com")
      assert relay.url == "wss://new-relay.example.com"
    end

    test "returns existing relay on second call (idempotent)" do
      {:ok, first} = Relay.get_or_create_relay("wss://idem.example.com")
      {:ok, second} = Relay.get_or_create_relay("wss://idem.example.com")
      assert first.id == second.id
    end

    test "strips trailing slash for lookup" do
      {:ok, first} = Relay.get_or_create_relay("wss://slash.example.com/")
      {:ok, second} = Relay.get_or_create_relay("wss://slash.example.com")
      assert first.id == second.id
    end
  end

  describe "create_or_update_relay/2" do
    test "creates when relay does not exist" do
      assert {:ok, relay} = Relay.create_or_update_relay("wss://brand-new.example.com", %{"description" => "new"})
      assert relay.description == "new"
    end

    test "updates when relay already exists" do
      {:ok, _} = Relay.create_or_update_relay("wss://existing.example.com", %{"description" => "old"})
      {:ok, updated} = Relay.create_or_update_relay("wss://existing.example.com", %{"description" => "updated"})
      assert updated.description == "updated"
    end
  end

  describe "get_relay_if_fresh/1" do
    test "returns relay when updated recently" do
      relay = relay_fixture(%{"url" => "wss://fresh.example.com"})
      assert %RelaySchema{} = Relay.get_relay_if_fresh("wss://fresh.example.com")
    end

    test "returns nil when relay does not exist" do
      assert is_nil(Relay.get_relay_if_fresh("wss://nonexistent.example.com"))
    end

    test "returns nil when relay is stale" do
      relay = relay_fixture(%{"url" => "wss://stale.example.com"})

      two_hours_ago = DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.truncate(:second)

      from(r in RelaySchema, where: r.id == ^relay.id)
      |> Repo.update_all(set: [updated_at: two_hours_ago])

      assert is_nil(Relay.get_relay_if_fresh("wss://stale.example.com"))
    end
  end
end
