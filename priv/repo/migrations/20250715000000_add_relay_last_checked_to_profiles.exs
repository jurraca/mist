
defmodule Mist.Repo.Migrations.AddRelayLastCheckedToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :relay_last_checked, :utc_datetime
    end

    create index(:profiles, [:relay_last_checked])
  end
end
