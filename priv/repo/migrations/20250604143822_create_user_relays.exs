defmodule Mist.Repo.Migrations.CreateUserRelays do
  use Ecto.Migration

  def change do
    create table(:user_relays) do
      add :purpose, :st_idring, null: false
      add :pubkey, :string, null: false
      add :relay_id, references(:relays, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:user_relays, [:pubkey, :relay_id], unique: true)
  end
end
