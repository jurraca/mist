defmodule Mist.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :pubkey, :string
      add :name, :string
      add :about, :string
      add :picture, :string
      add :display_name, :string
      add :website, :string
      add :banner, :string
      add :bot, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
