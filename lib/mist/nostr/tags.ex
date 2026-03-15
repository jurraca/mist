defmodule Mist.Nostr.Tags do
  use Ecto.Schema
  import Ecto.Changeset
  alias Mist.Nostr.Event

  schema "tags" do
    belongs_to :event, Event
    field :key, :string
    field :value, :string
    field :rest, {:array, :string}
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :key, :value, :rest])
    |> validate_required([:event_id, :key, :value])
  end
end
