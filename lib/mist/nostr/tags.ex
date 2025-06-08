defmodule Mist.Nostr.Tags do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :event_id, :string
    field :key, :string
    field :value, :string
    field :rest, {:array, :string}

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :key, :value, :rest])
    |> validate_required([:event_id, :key, :value])
  end
end
