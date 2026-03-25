defmodule Mist.Nostr.EventHandler do
  @moduledoc """
  Handles processing of different Nostr event types using pattern matching.
  """

  require Logger
  alias Nostr.Event
  alias Mist.Profile

  @doc """
  Processes events based on their kind and other attributes using pattern matching.
  """
  def process_event(%Event{kind: 0, pubkey: pubkey} = event) do
    with {:ok, content} <- Jason.decode(event.content),
          profile_attrs <- Map.put(content, "pubkey", pubkey),
         {:ok, _profile} <- Profile.create_or_update_profile(profile_attrs) do
      :ok
      # Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", profile)
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
    topic = "notes"
    event_map = fetch_author_data(event)

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

      {:ok, _} -> :ok
      {:error, changeset} ->
        Logger.debug("Failed to persist kind 1 event: #{inspect(changeset.errors)}")
    end

    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event_map)
  end

  def process_event(%Event{kind: 3, pubkey: pubkey, tags: tags} = event) do
    topic = "profiles"
    Profile.add_follow_list(pubkey, tags)
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  # Reactions (kind 7)
  def process_event(%Event{kind: 7, tags: tags} = _event) do
    case extract_referenced_note_id(tags) do
      {:ok, note_id} ->
        increment_reaction_count(note_id)
        Logger.debug("Reaction added to note #{note_id}")
      :error ->
        Logger.debug("Could not find referenced note in reaction event")
    end
  end

  # Boosts/Reposts (kind 6)  
  def process_event(%Event{kind: 6, tags: tags} = _event) do
    case extract_referenced_note_id(tags) do
      {:ok, note_id} ->
        increment_boost_count(note_id)
        Logger.debug("Boost added to note #{note_id}")
      :error ->
        Logger.debug("Could not find referenced note in boost event")
    end
  end

  # Zaps (kind 9735)
  def process_event(%Event{kind: 9735, tags: tags} = event) do
    case extract_referenced_note_id(tags) do
      {:ok, note_id} ->
        zap_amount = extract_zap_amount(event)
        increment_zap_count(note_id, zap_amount)
        Logger.debug("Zap added to note #{note_id} (amount: #{zap_amount})")
      :error ->
        Logger.debug("Could not find referenced note in zap event")
    end
  end

  def process_event(event) do
    Logger.debug("Unhandled event kind: #{event.kind}")
    topic = "events:#{event.kind}"
    # write to a general events table
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  defp persist_tags(db_event_id, tags) do
    rows =
      tags
      |> Enum.map(fn tag ->
        %{event_id: db_event_id, key: tag.type, value: tag.data, rest: tag.info || []}
      end)

    if rows != [] do
      Mist.Repo.insert_all("tags", rows, on_conflict: :nothing)
    end
  end

  defp fetch_author_data(event) do
    event_map = Map.from_struct(event)
    counts = get_interaction_counts(event.id)

    event_map
    |> Map.put(:author, nil)
    |> Map.put(:bot, false)
    |> Map.merge(counts)
  end

  # Helper functions for tracking interaction counts

  defp extract_referenced_note_id(tags) do
    case Enum.find(tags, fn tag -> tag.type == "e" end) do
      %{data: note_id} -> {:ok, note_id}
      _ -> :error
    end
  end

  defp extract_zap_amount(_event) do
    # Try to extract amount from bolt11 invoice in tags or content
    # For now, return a default amount - this would need proper bolt11 parsing
    1000
  end

  defp increment_reaction_count(note_id) do
    key = {:reactions, note_id}
    try do
      :ets.update_counter(:interaction_counts, key, 1)
    catch
      :error, :badarg ->
        # Key doesn't exist, insert default and retry
        :ets.insert(:interaction_counts, {key, 0})
        :ets.update_counter(:interaction_counts, key, 1)
    end
    broadcast_count_update(note_id)
  end

  defp increment_boost_count(note_id) do
    key = {:boosts, note_id}
    try do
      :ets.update_counter(:interaction_counts, key, 1)
    catch
      :error, :badarg ->
        # Key doesn't exist, insert default and retry
        :ets.insert(:interaction_counts, {key, 0})
        :ets.update_counter(:interaction_counts, key, 1)
    end
    broadcast_count_update(note_id)
  end

  defp increment_zap_count(note_id, amount) do
    key = {:zaps, note_id}
    try do
      :ets.update_counter(:interaction_counts, key, amount)
    catch
      :error, :badarg ->
        # Key doesn't exist, insert default and retry
        :ets.insert(:interaction_counts, {key, 0})
        :ets.update_counter(:interaction_counts, key, amount)
    end
    broadcast_count_update(note_id)
  end

  defp get_interaction_counts(note_id) do
    reaction_count = case :ets.lookup(:interaction_counts, {:reactions, note_id}) do
      [{_key, count}] -> count
      [] -> 0
    end
    
    boost_count = case :ets.lookup(:interaction_counts, {:boosts, note_id}) do
      [{_key, count}] -> count
      [] -> 0
    end
    
    zap_amount = case :ets.lookup(:interaction_counts, {:zaps, note_id}) do
      [{_key, amount}] -> amount
      [] -> 0
    end
    
    %{
      reaction_count: reaction_count,
      boost_count: boost_count,
      zap_amount: zap_amount
    }
  end

  defp broadcast_count_update(note_id) do
    counts = get_interaction_counts(note_id)
    Phoenix.PubSub.broadcast(Mist.PubSub, "note_counts", %{note_id: note_id, counts: counts})
  end
end
