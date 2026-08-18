defmodule Mist.Nostr.EventHandler do
  @moduledoc """
  Handles processing of different Nostr event types using pattern matching.

  Persists note events (kind 1) and interaction events (reactions 6, boosts 7,
  zap receipts 9735) to the DB, and broadcasts UI updates over PubSub.
  Interaction counts are always computed from the DB (see `Mist.Notes.counts_for/1`).
  """

  require Logger
  alias NostrCore.Event
  alias Mist.{Notes, Profile}
  alias Mist.Nostr.Tags

  @interaction_kinds [6, 7, 9735]

  @doc """
  Processes events based on their kind and other attributes using pattern matching.
  """
  def process_event(%Event{kind: 0, pubkey: pubkey} = event) do
    with {:ok, content} <- Jason.decode(event.content),
         {:ok, profile} <-
           content
           |> Map.put("pubkey", pubkey)
           |> Profile.create_or_update_profile() do
      Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", profile)
    else
      {:error, reason} ->
        Logger.error("Failed to process profile event: #{inspect(reason)}")
    end
  end

  def process_event(%Event{kind: 10002, pubkey: pubkey, tags: tags} = _event) do
    case Profile.add_user_relays(pubkey, tags) do
      {:error, :profile_not_found} ->
        Logger.debug("Profile not found for relay event: #{pubkey}")

      {count, _} when count > 0 ->
        :ok

      _ ->
        Logger.debug("No relay events processed for #{pubkey}")
    end
  end

  def process_event(%Event{kind: 1} = event) do
    persist_event(event)
    Phoenix.PubSub.broadcast(Mist.PubSub, "notes", Notes.note_view(event))
  end

  def process_event(%Event{kind: 3, pubkey: pubkey, tags: tags} = event) do
    topic = "profiles"
    Profile.add_follow_list(pubkey, tags)
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  # Reactions (7), boosts/reposts (6), zap receipts (9735)
  def process_event(%Event{kind: kind, tags: tags} = event) when kind in @interaction_kinds do
    persist_event(event)

    case extract_referenced_note_id(tags) do
      {:ok, note_id} ->
        broadcast_count_update(note_id)

      :error ->
        Logger.debug("Could not find referenced note in kind #{kind} event")
    end
  end

  def process_event(event) do
    Logger.debug("Unhandled event kind: #{event.kind}")
    topic = "events:#{event.kind}"
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  defp persist_event(%Event{} = event) do
    attrs = %{
      event_id: event.id,
      pubkey: event.pubkey,
      created_at: event.created_at,
      kind: event.kind,
      content: event.content,
      sig: event.sig
    }

    case Mist.Repo.insert(
           Mist.Nostr.Event.changeset(%Mist.Nostr.Event{}, attrs),
           on_conflict: :nothing,
           conflict_target: [:event_id]
         ) do
      {:ok, %{id: id}} when not is_nil(id) ->
        persist_tags(id, event.tags)

      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.debug("Failed to persist kind #{event.kind} event: #{inspect(changeset.errors)}")
    end
  end

  defp persist_tags(db_event_id, tags) do
    rows =
      Enum.map(tags, fn tag ->
        %{event_id: db_event_id, key: tag.type, value: tag.data, rest: tag.info || []}
      end)

    if rows != [] do
      # NOTE: must go through the Tags schema — schemaless insert_all with a
      # table name would bind the `rest` list as an iolist (corrupted string)
      # instead of dumping {:array, :string} to JSON.
      Mist.Repo.insert_all(Tags, rows, on_conflict: :nothing)
    end
  end

  defp extract_referenced_note_id(tags) do
    case Enum.find(tags, fn tag -> tag.type == "e" end) do
      %{data: note_id} -> {:ok, note_id}
      _ -> :error
    end
  end

  defp broadcast_count_update(note_id) do
    counts = Notes.counts_for([note_id]) |> Map.get(note_id, Notes.zero_counts())
    Phoenix.PubSub.broadcast(Mist.PubSub, "note_counts", %{note_id: note_id, counts: counts})
  end
end
