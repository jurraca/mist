defmodule Mist.Repo.Migrations.AddRelayUrl do
  use Ecto.Migration

  def change do
    alter table(:relays) do
      add :url, :string
    end
  end
end
