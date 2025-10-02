defmodule Mist.Profile.FollowList do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Profile.{Profile, Follows, FollowListMembers}

  schema "follow_lists" do
    field :name, :string
    field :description, :string
    field :color, :string

    belongs_to :profile, Profile
    many_to_many :follows, Follows,
      join_through: FollowListMembers,
      join_keys: [follow_list_id: :id, follow_id: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(follow_list, attrs) do
    follow_list
    |> cast(attrs, [:name, :description, :color, :profile_id])
    |> validate_required([:name, :profile_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint([:profile_id, :name])
  end
end
