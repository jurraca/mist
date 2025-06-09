defmodule Mist.Repo.Migrations.CreateTagsTable do
  use Ecto.Migration

  def change do
    create table("tags") do
      add :event_id, references("events")
      add :key, :string
      add :value, :string
      add :rest, {:array, :string}
    end
  end
end
