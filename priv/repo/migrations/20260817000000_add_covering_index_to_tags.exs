defmodule Mist.Repo.Migrations.AddCoveringIndexToTags do
  use Ecto.Migration

  def change do
    # Covering index for interaction-count / reply-edge queries:
    # tags WHERE key = 'e' AND value IN (note_ids) -> event_id without
    # touching the table; the join to events then goes by rowid.
    create index(:tags, [:key, :value, :event_id])
  end
end
