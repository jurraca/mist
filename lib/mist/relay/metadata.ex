defmodule Mist.Relay.Metadata do
  use Ecto.Schema
  import Ecto.Changeset

  schema "relay_metadata" do
    field :name, :string
    field :description, :string
    field :banner, :string
    field :icon, :string
    field :pubkey, :string
    field :contact, :string
    field :supported_nips, {:array, :integer}
    field :software, :string
    field :version, :string

    belongs_to :relay, Mist.Relay.Info

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [:relay_id, :name, :description, :banner, :icon, :pubkey, :contact, :supported_nips, :software, :version])
    |> validate_required([:relay_id])
    |> unique_constraint(:relay_id)
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
