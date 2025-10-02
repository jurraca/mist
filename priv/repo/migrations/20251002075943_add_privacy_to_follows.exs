defmodule Mist.Repo.Migrations.AddPrivacyToFollows do
  use Ecto.Migration

  def change do
    alter table(:follows) do
      add :is_public, :boolean, default: false, null: false
      add :notes, :text
    end

    create index(:follows, [:is_public])
  end
end
