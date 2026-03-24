defmodule Mist.Relay.Info do
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
    |> cast(attrs, [:name, :url, :description, :banner, :icon, :pubkey, :contact, :supported_nips, :software, :version])
    |> validate_required([:url])
    |> unique_constraint([:url])
  end

  def get("wss" <> rest), do: get("https" <> rest)

  def get("ws" <> rest), do: get("http" <> rest)

  def get(url) do
    header = %{"accept" => "application/nostr+json"}
    case Req.get(url, headers: header, receive_timeout: 5_000) do
      {:ok, resp} -> {:ok, resp.body}
      err -> err
    end
  end
end
