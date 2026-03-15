defmodule Mist.Profile.Follows do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Profile.{FollowList, FollowListMembers, Profile}

  schema "follows" do
    belongs_to :follower, Profile
    belongs_to :followed, Profile
    field :is_public, :boolean, default: false
    field :notes, :string
    field :petname, :string

    many_to_many :lists, FollowList,
      join_through: FollowListMembers,
      join_keys: [follow_id: :id, follow_list_id: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(follows, attrs) do
    follows
    |> cast(attrs, [:follower_id, :followed_id, :is_public, :notes, :petname])
    |> validate_required([:follower_id, :followed_id])
    |> unique_constraint([:follower_id, :followed_id])
  end
end
