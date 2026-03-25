defmodule Mist.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table("subscriptions") do
      add :name, :string, null: false
      add :kinds, {:array, :integer}
      add :authors, {:array, :string}
      add :since, :integer
      add :until, :integer
      add :limit, :integer
      add :tags, :map

      timestamps(type: :utc_datetime)
    end
  end
end
