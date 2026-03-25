defmodule Mist.Repo.Migrations.AddIndexesToEventsAndTags do
  use Ecto.Migration

  def change do
    create index(:events, [:kind, :created_at])
    create index(:events, [:pubkey, :kind, :created_at])
    create index(:tags, [:event_id])
    create index(:tags, [:key, :value])
  end
end
