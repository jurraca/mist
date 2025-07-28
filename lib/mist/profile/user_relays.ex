defmodule Mist.Profile.UserRelays do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Relay.Relay

  schema "user_relays" do
    field :purpose, Ecto.Enum, values: [:r, :w, :rw]
    field :pubkey, :string
    belongs_to :relay, Relay

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay_metadata, attrs) do
    relay_metadata
    |> cast(attrs, [:relay_id, :pubkey, :purpose, :inserted_at, :updated_at])
    |> validate_required([:relay_id, :pubkey, :purpose])
    |> unique_constraint([:relay_id, :pubkey])
  end

  def parse_tag(%{data: relay_url, info: info}) do
    {:ok, relay} = Mist.Relay.get_or_create_relay(relay_url)
    purpose = translate_rw(info)
    {:ok, %{relay_id: relay.id, purpose: purpose}}
  end

  def parse_tag(_tag) do
    {:error, "missing a required key in tag: data or info"}
  end

  defp translate_rw(["read"]), do: :r
  defp translate_rw(["write"]), do: :w
  defp translate_rw(_), do: :rw
end
