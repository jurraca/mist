defmodule Mist.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :name, :string
    field :kinds, {:array, :integer}
    field :authors, {:array, :string}
    field :since, :integer
    field :until, :integer
    field :limit, :integer
    field :tags, :map

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:name, :kinds, :authors, :since, :until, :limit, :tags])
    |> validate_required([:name])
    |> validate_length(:name, min: 1)
    |> validate_number(:since, greater_than_or_equal_to: 0)
    |> validate_number(:until, greater_than_or_equal_to: 0)
    |> validate_number(:limit, greater_than_or_equal_to: 0)
  end
end
