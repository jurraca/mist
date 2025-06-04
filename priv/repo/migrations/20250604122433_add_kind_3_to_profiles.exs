defmodule Mist.Repo.Migrations.AddKind3ToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :relay, :string
      add :petname, :string
    end
  end
end
