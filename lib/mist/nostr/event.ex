defmodule Mist.Nostr.Event do
  use Ecto.Schema
  import Ecto.Changeset
  alias Mist.Nostr.Tags

  schema "events" do
    field :event_id, :string
    field :sig, :string
    field :kind, :integer
    field :pubkey, :string
    field :created_at, :integer
    field :content, :string
    has_many :tags, Tags

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :pubkey, :created_at, :kind, :content, :sig])
    |> validate_required([:event_id, :pubkey, :created_at, :kind, :tags, :content, :sig])
    |> validate_length(:pubkey, is: 64)
    |> validate_length(:event_id, is: 64)
    |> validate_length(:sig, is: 128)
    |> validate_number(:kind, greater_than_or_equal_to: 0, less_than: 65535)
    |> unique_constraint([:event_id])
  end

  def format_attrs(%{"id" => event_id, "content" => content} = attrs) do
    attrs
    |> Map.put("event_id", event_id)
    |> Map.update!("content", fn x -> if(content == "", do: nil, else: content) end)
  end
end
