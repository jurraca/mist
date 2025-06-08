defmodule Mist.Repo.Migrations.CreateProfilesUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:profiles, [:pubkey])
  end
end
