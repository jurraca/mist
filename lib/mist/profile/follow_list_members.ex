defmodule Mist.Profile.FollowListMembers do
  use Ecto.Schema
  import Ecto.Changeset

  alias Mist.Profile.{Follows, FollowList}

  schema "follow_list_members" do
    belongs_to :follow, Follows
    belongs_to :follow_list, FollowList

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:follow_id, :follow_list_id])
    |> validate_required([:follow_id, :follow_list_id])
    |> unique_constraint([:follow_id, :follow_list_id])
  end
end
