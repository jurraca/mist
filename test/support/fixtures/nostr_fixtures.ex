defmodule Mist.NostrFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Mist.Nostr` context.
  """

  @doc """
  Generate a relay.
  """
  def relay_fixture(attrs \\ %{}) do
    {:ok, relay} =
      attrs
      |> Enum.into(%{
        banner: "some banner",
        contact: "some contact",
        description: "some description",
        icon: "some icon",
        name: "some name",
        pubkey: "some pubkey",
        software: "some software",
        supported_nips: [1, 2],
        version: "some version"
      })
      |> Mist.Nostr.create_relay()

    relay
  end
end
