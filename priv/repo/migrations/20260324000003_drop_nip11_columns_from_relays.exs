defmodule Mist.Repo.Migrations.DropNip11ColumnsFromRelays do
  use Ecto.Migration

  def up do
    alter table(:relays) do
      remove :description
      remove :banner
      remove :icon
      remove :pubkey
      remove :contact
      remove :supported_nips
      remove :software
      remove :version
    end
  end

  def down do
    alter table(:relays) do
      add :description, :text
      add :banner, :string
      add :icon, :string
      add :pubkey, :string
      add :contact, :string
      add :supported_nips, {:array, :integer}
      add :software, :string
      add :version, :string
    end
  end
end
