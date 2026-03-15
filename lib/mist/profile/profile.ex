defmodule Mist.Profile.Profile do
  use Ecto.Schema
  import Ecto.Changeset
  alias Mist.Profile.{Follows, UserRelays}

  schema "profiles" do
    field :name, :string
    field :pubkey, :string
    field :relay, :string
    field :about, :string
    field :picture, :string
    field :display_name, :string
    field :website, :string
    field :banner, :string
    field :bot, :boolean, default: false
    field :relay_last_checked, :utc_datetime
    many_to_many :following, __MODULE__, join_through: Follows, join_keys: [follower_id: :id, followed_id: :id]
    many_to_many :followers, __MODULE__, join_through: Follows, join_keys: [followed_id: :id, follower_id: :id]
    has_many :user_relays, UserRelays, foreign_key: :profile_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:pubkey, :name, :relay, :about, :picture, :display_name, :website, :banner, :bot])
    |> validate_required([:pubkey])
    |> validate_length(:pubkey, is: 64)
    |> unique_constraint([:pubkey])
  end
end
