defmodule Mist.Repo.Migrations.AddProfileIdToUserRelays do
  use Ecto.Migration

  def up do
    alter table(:user_relays) do
      add :profile_id, references(:profiles, on_delete: :delete_all)
    end

    execute """
    UPDATE user_relays
    SET profile_id = profiles.id
    FROM profiles
    WHERE user_relays.pubkey = profiles.pubkey
    """

    create index(:user_relays, [:profile_id])
  end

  def down do
    drop index(:user_relays, [:profile_id])

    alter table(:user_relays) do
      remove :profile_id
    end
  end
end
