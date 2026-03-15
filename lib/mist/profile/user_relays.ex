defmodule Mist.Profile.UserRelays do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Relay.Relay

  schema "user_relays" do
    field :purpose, Ecto.Enum, values: [:r, :w, :rw]
    field :pubkey, :string
    belongs_to :relay, Relay

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay_metadata, attrs) do
    relay_metadata
    |> cast(attrs, [:relay_id, :pubkey, :purpose, :inserted_at, :updated_at])
    |> validate_required([:relay_id, :pubkey, :purpose])
    |> unique_constraint([:relay_id, :pubkey])
  end

end
