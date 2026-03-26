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

  @max_note_length 10_000

  def change_note(event, attrs \\ %{}) do
    event
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> validate_length(:content, min: 1, max: @max_note_length)
  end

  @doc false
  def changeset(event, attrs) do
    attrs =
      Map.update!(attrs, :created_at, fn dt ->
        if is_integer(dt) do
          dt
        else
          DateTime.to_unix(dt)
        end
      end)

    event
    |> cast(attrs, [:event_id, :pubkey, :created_at, :kind, :content, :sig])
    |> validate_required([:event_id, :pubkey, :created_at, :kind, :content, :sig])
    |> validate_length(:pubkey, is: 64)
    |> validate_length(:event_id, is: 64)
    |> validate_length(:sig, is: 128)
    |> validate_number(:kind, greater_than_or_equal_to: 0, less_than: 65535)
    |> validate_number(:created_at, greater_than: 0)
    |> unique_constraint([:event_id])
  end
end
