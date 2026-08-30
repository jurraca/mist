defmodule Mist.Relay.Info do
  use Ecto.Schema
  import Ecto.Changeset

  schema "relays" do
    field :name, :string
    field :url, :string
    field :failure_count, :integer, default: 0
    field :blacklisted_at, :utc_datetime
    field :blacklist_reason, :string

    has_one :metadata, Mist.Relay.Metadata, foreign_key: :relay_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay, attrs) do
    attrs =
      case attrs do
        %{"url" => url} when is_binary(url) and url != "" ->
          uri = URI.parse(url)
          name = uri.host
          normalized_url = URI.to_string(uri) |> String.trim("/")
          attrs |> Map.put("url", normalized_url) |> Map.put("name", name)

        _ ->
          attrs
      end

    relay
    |> cast(attrs, [:name, :url, :failure_count, :blacklisted_at, :blacklist_reason])
    |> validate_required([:url])
    |> unique_constraint([:url])
  end
end
