defmodule Mist.Repo.Migrations.CreateRelayMetadata do
  use Ecto.Migration

  def up do
    create table(:relay_metadata) do
      add :relay_id, references(:relays, on_delete: :delete_all), null: false
      add :name, :string
      add :description, :text
      add :banner, :string
      add :icon, :string
      add :pubkey, :string
      add :contact, :string
      add :supported_nips, {:array, :integer}
      add :software, :string
      add :version, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relay_metadata, [:relay_id])
  end

  def down do
    drop table(:relay_metadata)
  end
end
