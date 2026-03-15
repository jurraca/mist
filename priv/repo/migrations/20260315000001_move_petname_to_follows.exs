defmodule Mist.Repo.Migrations.MovePetnameToFollows do
  use Ecto.Migration

  def up do
    alter table(:follows) do
      add :petname, :string
    end

    execute """
    UPDATE follows
    SET petname = profiles.petname
    FROM profiles
    WHERE follows.followed_id = profiles.id
      AND profiles.petname IS NOT NULL
    """

    alter table(:profiles) do
      remove :petname
    end
  end

  def down do
    alter table(:profiles) do
      add :petname, :string
    end

    execute """
    UPDATE profiles
    SET petname = follows.petname
    FROM follows
    WHERE follows.followed_id = profiles.id
      AND follows.petname IS NOT NULL
    """

    alter table(:follows) do
      remove :petname
    end
  end
end
