defmodule Mist.NostrFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the Relay, Profile, and Event contexts.
  """

  def unique_pubkey do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  def unique_event_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  def unique_sig do
    :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)
  end

  def relay_fixture(attrs \\ %{}) do
    url = Map.get(attrs, :url, Map.get(attrs, "url", "wss://relay.example.com"))

    {:ok, relay} = Mist.Relay.create_relay(%{"url" => url})
    relay
  end

  def profile_fixture(attrs \\ %{}) do
    merged =
      attrs
      |> Enum.into(%{
        pubkey: Map.get(attrs, :pubkey, unique_pubkey())
      })

    {:ok, profile} = Mist.Profile.create_profile(merged)
    profile
  end

  def event_fixture(attrs \\ %{}) do
    merged =
      attrs
      |> Enum.into(%{
        event_id: Map.get(attrs, :event_id, unique_event_id()),
        pubkey: Map.get(attrs, :pubkey, unique_pubkey()),
        created_at: Map.get(attrs, :created_at, System.os_time(:second)),
        kind: Map.get(attrs, :kind, 1),
        content: Map.get(attrs, :content, "hello world"),
        sig: Map.get(attrs, :sig, unique_sig())
      })

    {:ok, event} = Mist.Repo.insert(Mist.Nostr.Event.changeset(%Mist.Nostr.Event{}, merged))
    event
  end

  def follows_fixture(follower_pubkey, followed_pubkey) do
    {:ok, follow} = Mist.Profile.follow_profile(follower_pubkey, followed_pubkey)
    follow
  end

  def user_relay_fixture(pubkey, relay_url, purpose \\ :rw) do
    {:ok, profile} = Mist.Profile.get_or_create_profile(pubkey)
    {:ok, relay} = Mist.Relay.get_or_create_relay(relay_url)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Mist.Repo.insert_all(
      Mist.Profile.UserRelays,
      [%{relay_id: relay.id, pubkey: pubkey, profile_id: profile.id, purpose: purpose, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )
  end

  def follow_list_fixture(profile_id, attrs \\ %{}) do
    merged =
      attrs
      |> Enum.into(%{
        name: "Test List",
        description: "A test follow list"
      })

    {:ok, list} = Mist.Profile.create_follow_list(profile_id, merged)
    list
  end
end
