defmodule Mist.Repo.Migrations.CreateRelays do
  use Ecto.Migration

  def change do
    create table(:relays) do
      add :name, :string
      add :url, :string
      add :description, :string
      add :banner, :string
      add :icon, :string
      add :pubkey, :string
      add :contact, :string
      add :supported_nips, {:array, :integer}
      add :software, :string
      add :version, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relays, [:url])
  end
end
