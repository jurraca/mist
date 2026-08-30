defmodule Mist.RelayTest do
  use Mist.DataCase

  alias Mist.Relay
  alias Mist.Relay.Info, as: RelaySchema
  alias Mist.Relay.Metadata

  import Mist.NostrFixtures
  import Ecto.Query

  describe "CRUD" do
    test "list_relays/0 returns all relays" do
      relay = relay_fixture()
      [listed] = Relay.list_relays()
      assert listed.id == relay.id
      assert listed.url == relay.url
    end

    test "get_relay!/1 returns the relay with given id" do
      relay = relay_fixture()
      found = Relay.get_relay!(relay.id)
      assert found.id == relay.id
      assert found.url == relay.url
    end

    test "create_relay/1 with valid data creates a relay" do
      attrs = %{"url" => "wss://relay.example.com"}

      assert {:ok, %RelaySchema{} = relay} = Relay.create_relay(attrs)
      assert relay.url == "wss://relay.example.com"
    end

    test "create_relay/1 without url returns error changeset" do
      assert {:error, changeset} = Relay.create_relay(%{"name" => "no url"})
      assert %{url: _} = errors_on(changeset)
    end

    test "update_relay/2 with valid data updates the relay" do
      relay = relay_fixture()

      update_attrs = %{"url" => "wss://updated.example.com"}

      assert {:ok, %RelaySchema{} = updated} = Relay.update_relay(relay, update_attrs)
      assert updated.url == "wss://updated.example.com"
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
    test "creates relay and metadata when relay does not exist" do
      assert {:ok, %RelaySchema{} = relay} =
               Relay.create_or_update_relay("wss://brand-new.example.com", %{"description" => "new"})

      meta = Repo.get_by(Metadata, relay_id: relay.id)
      assert meta.description == "new"
    end

    test "updates metadata when relay already exists" do
      {:ok, _} = Relay.create_or_update_relay("wss://existing.example.com", %{"description" => "old"})
      {:ok, updated} = Relay.create_or_update_relay("wss://existing.example.com", %{"description" => "updated"})
      meta = Repo.get_by(Metadata, relay_id: updated.id)
      assert meta.description == "updated"
    end
  end

  describe "get_relay_if_fresh/1" do
    test "returns relay when metadata was updated recently" do
      {:ok, _} = Relay.create_or_update_relay("wss://fresh.example.com", %{"description" => "fresh"})
      assert %RelaySchema{} = Relay.get_relay_if_fresh("wss://fresh.example.com")
    end

    test "returns nil when relay does not exist" do
      assert is_nil(Relay.get_relay_if_fresh("wss://nonexistent.example.com"))
    end

    test "returns nil when metadata is stale" do
      {:ok, relay} = Relay.create_or_update_relay("wss://stale.example.com", %{"description" => "stale"})

      two_hours_ago = DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.truncate(:second)

      from(m in Metadata, where: m.relay_id == ^relay.id)
      |> Repo.update_all(set: [updated_at: two_hours_ago])

      assert is_nil(Relay.get_relay_if_fresh("wss://stale.example.com"))
    end

    test "returns nil when relay has no metadata" do
      {:ok, _relay} = Relay.create_relay(%{"url" => "wss://no-meta.example.com"})
      assert is_nil(Relay.get_relay_if_fresh("wss://no-meta.example.com"))
    end
  end

  describe "connect_opts/0" do
    test "bounds the socket reconnect loop instead of retrying forever" do
      opts = Relay.connect_opts()

      assert Keyword.get(opts, :max_attempts) == 5
      # Backoff bounds are sane: at least a second, at most a minute.
      assert Keyword.get(opts, :backoff_min) >= 1_000
      assert Keyword.get(opts, :backoff_max) <= 60_000
      assert Keyword.get(opts, :backoff_min) < Keyword.get(opts, :backoff_max)
    end
  end
end
