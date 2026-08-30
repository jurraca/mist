defmodule Mist.Repo.Migrations.AddRelayHealthColumns do
  use Ecto.Migration

  def change do
    alter table(:relays) do
      add :failure_count, :integer, default: 0
      add :blacklisted_at, :utc_datetime
      add :blacklist_reason, :string
    end
  end
end
