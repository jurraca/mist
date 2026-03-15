defmodule Mist.Relay.Relay do
  use Ecto.Schema
  import Ecto.Changeset

  schema "relays" do
    field :name, :string
    field :url, :string
    field :version, :string
    field :description, :string
    field :banner, :string
    field :icon, :string
    field :pubkey, :string
    field :contact, :string
    field :supported_nips, {:array, :integer}
    field :software, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay, %{"url" => url} = attrs) do
    uri = URI.parse(url)
    name = uri.host
    url = URI.to_string(uri) |> String.trim("/")
    attrs = attrs |> Map.put("url", url) |> Map.put("name", name)

    relay
    |> cast(attrs, [:name, :url, :description, :banner, :icon, :pubkey, :contact, :supported_nips, :software, :version])
    |> validate_required([:url])
    |> unique_constraint([:url])
  end

  def changeset(relay, _attrs) do
    relay
    |> change()
    |> add_error(:url, "is a required attribute")
  end
end
