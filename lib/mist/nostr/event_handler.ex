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
    with {count, _} <- Profile.add_user_relays(pubkey, tags),
         true <- count > 0 do
      :ok
    else
      _ ->
        Logger.debug("No relay events processed for #{pubkey}")
    end
  end

  def process_event(%Event{kind: 1} = event) do
    topic = "notes"
    # Write to a kind-1-only DB table
    # Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  def process_event(%Event{kind: 3, pubkey: pubkey, tags: tags} = event) do
    dbg(event)
    topic = "profiles"
    Profile.add_follow_list(pubkey, tags)
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end

  def process_event(event) do
    dbg(event)
    topic = "events:#{event.kind}"
    # write to a general events table
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)
  end
end
