defmodule Mist.Repo.Migrations.AddEventTable do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :event_id, :string
      add :pubkey, :string
      add :created_at, :integer
      add :kind, :integer
      add :content, :string
      add :sig, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:events, [:event_id])
  end
end
