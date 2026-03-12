defmodule Mist.Nostr.Event do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Mist.Nostr.Tags

  @default_since_window Application.compile_env(:mist, :subscription_since_window, 86_400)
  @default_limit Application.compile_env(:mist, :subscription_limit, 500)

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
    |> validate_required([:event_id, :pubkey, :created_at, :kind, :content, :sig])
    |> validate_length(:pubkey, is: 64)
    |> validate_length(:event_id, is: 64)
    |> validate_length(:sig, is: 128)
    |> validate_number(:kind, greater_than_or_equal_to: 0, less_than: 65535)
    |> unique_constraint([:event_id])
  end

  def format_attrs(%{"id" => event_id, "content" => content} = attrs) do
    attrs
    |> Map.put("event_id", event_id)
    |> Map.update!("content", fn content -> if(content == "", do: nil, else: content) end)
  end

  def max_created_at(opts \\ []) do
    kinds = Keyword.get(opts, :kinds, [])
    authors = Keyword.get(opts, :authors, [])

    query =
      from(e in __MODULE__, select: max(e.created_at))
      |> maybe_filter_kinds(kinds)
      |> maybe_filter_authors(authors)

    Mist.Repo.one(query)
  end

  def since_for_filter(opts \\ []) do
    case max_created_at(opts) do
      nil -> System.os_time(:second) - @default_since_window
      ts -> ts
    end
  end

  def default_limit, do: @default_limit

  defp maybe_filter_kinds(query, []), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  defp maybe_filter_authors(query, []), do: query
  defp maybe_filter_authors(query, authors), do: where(query, [e], e.pubkey in ^authors)
end
