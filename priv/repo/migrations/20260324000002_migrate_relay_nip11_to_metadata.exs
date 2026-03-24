defmodule Mist.Repo.Migrations.MigrateRelayNip11ToMetadata do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO relay_metadata (relay_id, name, description, banner, icon, pubkey, contact, supported_nips, software, version, inserted_at, updated_at)
    SELECT id, name, description, banner, icon, pubkey, contact, supported_nips, software, version, datetime('now'), datetime('now')
    FROM relays
    WHERE description IS NOT NULL
       OR banner IS NOT NULL
       OR icon IS NOT NULL
       OR pubkey IS NOT NULL
       OR contact IS NOT NULL
       OR supported_nips IS NOT NULL
       OR software IS NOT NULL
       OR version IS NOT NULL
    """
  end

  def down do
    execute "DELETE FROM relay_metadata"
  end
end
