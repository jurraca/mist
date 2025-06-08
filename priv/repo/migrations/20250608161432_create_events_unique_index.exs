defmodule Mist.Repo.Migrations.CreateEventsUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:events, [:event_id])
  end
end
