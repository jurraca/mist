defmodule Mist.Repo.Migrations.CreateFollowLists do
  use Ecto.Migration

  def change do
    create table(:follow_lists) do
      add :name, :string, null: false
      add :description, :text
      add :color, :string
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:follow_lists, [:profile_id])
    create unique_index(:follow_lists, [:profile_id, :name])
  end
end
