defmodule Mist.Repo.Migrations.CreateRelayUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:relays, [:url])
  end
end
