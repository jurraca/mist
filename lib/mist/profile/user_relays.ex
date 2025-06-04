defmodule Mist.Profile.UserRelays do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Relay.Relay
  alias Mist.Profile.Profile

  schema "user_relays" do
    field :purpose, Ecto.Enum, values: [:r, :w, :rw]
    belongs_to :pubkey, Profile
    belongs_to :relay, Relay

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay_metadata, attrs) do
    relay_metadata
    |> cast(attrs, [:relay_id, :profile_id, :purpose])
    |> validate_required([:relay_id, :profile_id, :purpose])
  end
end
