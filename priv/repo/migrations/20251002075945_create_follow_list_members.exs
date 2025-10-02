defmodule Mist.Repo.Migrations.CreateFollowListMembers do
  use Ecto.Migration

  def change do
    create table(:follow_list_members) do
      add :follow_id, references(:follows, on_delete: :delete_all), null: false
      add :follow_list_id, references(:follow_lists, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:follow_list_members, [:follow_id])
    create index(:follow_list_members, [:follow_list_id])
    create unique_index(:follow_list_members, [:follow_id, :follow_list_id])
  end
end
