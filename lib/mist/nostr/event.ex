defmodule Mist.Nostr.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field :event_id, :string
    field :sig, :string
    field :kind, :integer
    field :pubkey, :string
    field :created_at, :integer
    field :tags, {:array, :string}
    field :content, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :pubkey, :created_at, :kind, :tags, :content, :sig])
    |> validate_required([:event_id, :pubkey, :created_at, :kind, :tags, :content, :sig])
  end
end
