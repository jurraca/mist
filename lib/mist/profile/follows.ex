defmodule Mist.Profile.Follows do
  use Ecto.Schema
  import Ecto.Changeset

  schema "follows" do

    field :follower_id, :id
    field :followed_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(follows, attrs) do
    follows
    |> cast(attrs, [])
    |> validate_required([])
  end
end
