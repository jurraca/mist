defmodule Mist.Profile.UserRelays do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Relay.Relay
  alias Mist.Repo
  alias Mist.Profile.Profile

  schema "user_relays" do
    field :purpose, Ecto.Enum, values: [:r, :w, :rw]
    belongs_to :pubkey, Profile
    belongs_to :relay, Relay

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relay_metadata, attrs) do
    relay_metadata
    |> cast(attrs, [:relay_id, :pubkey_id, :purpose, :inserted_at, :updated_at])
    |> validate_required([:relay_id, :pubkey_id, :purpose])
    |> unique_constraint([:relay_id, :pubkey_id])
  end

  def parse_tag(%{data: relay_url} = tag) do
    {:ok, relay} = Mist.Relay.get_or_create_relay(relay_url)
    purpose = if Map.get(tag, :info) do
      tag.info
      |> Enum.at(0)
      |> translate_rw()
      else
        :rw
      end
    {:ok, %{relay_id: relay.id, purpose: purpose}}
  end

  def parse_tag(_tag) do
    {:error, "missing 'data' key in tag"}
  end

  defp translate_rw("read"), do: :r
  defp translate_rw("write"), do: :w
  defp translate_rw(_), do: :rw
end
