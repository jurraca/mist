defmodule Mist.Repo.Migrations.CreateTagsTable do
  use Ecto.Migration

  def change do
    alter table("events") do
      remove :tags
    end

    create table("tags") do
      add :event_id, references("events")
      add :key, :string
      add :value, :string
      add :rest, {:array, :string}
    end
  end
end
