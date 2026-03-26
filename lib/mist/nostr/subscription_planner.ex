defmodule Mist.Nostr.SubscriptionPlanner do
  @moduledoc """
  Manages relay subscriptions for the current user's follow list.

  Maintains state `%{relay_url => MapSet.t(pubkeys)}` representing which pubkeys
  are currently subscribed on each relay. On startup, reads the follow list and
  their write relay metadata from the database and opens one consolidated
  subscription per relay. When a new follow is added, reacts to a PubSub message
  and opens an incremental subscription only for the newly covered pubkeys —
  existing subscriptions are never closed or reopened.
  """

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Mist.{Notes, Profile, Relay, Repo}
  alias Mist.Profile.{UserRelays}
  alias Mist.Relay.Info
  alias NostrEx.Subscription

  @pubsub Mist.PubSub
  @new_follow_topic "profile:new_follow"
  @feed_kinds [1, 6, 7]

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{relay_pubkeys: %{}}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    Phoenix.PubSub.subscribe(@pubsub, @new_follow_topic)
    {:ok, state, {:continue, :load_from_db}}
  end

  @impl GenServer
  def handle_continue(:load_from_db, state) do
    case Mist.Nostr.Signer.get_public_key() do
      {:ok, my_pubkey} ->
        new_state = load_all_follows(my_pubkey, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("SubscriptionPlanner: could not get public key at startup (#{inspect(reason)}), starting empty")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:new_follow, followed_pubkey}, state) do
    Logger.debug("SubscriptionPlanner: new follow event for #{String.slice(followed_pubkey, 0, 8)}...")
    new_state = open_sub_for_pubkey(followed_pubkey, state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("SubscriptionPlanner: unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  defp load_all_follows(my_pubkey, state) do
    case Profile.get_by_pubkey(my_pubkey) do
      {:ok, profile} ->
        follows = Repo.preload(profile, :following).following

        if follows == [] do
          Logger.info("SubscriptionPlanner: no follows found in DB, starting empty")
          state
        else
          relay_to_pubkeys = Profile.get_write_relays_by_relay(follows)
          Logger.info("SubscriptionPlanner: loading #{length(follows)} follows across #{map_size(relay_to_pubkeys)} relay(s)")

          Enum.reduce(relay_to_pubkeys, state, fn {relay_url, pubkeys}, acc ->
            connect_and_subscribe(relay_url, pubkeys, acc)
          end)
        end

      {:error, _} ->
        Logger.info("SubscriptionPlanner: profile not in DB yet, starting empty")
        state
    end
  end

  defp open_sub_for_pubkey(pubkey, state) do
    write_relays = get_write_relays_for_pubkey(pubkey)

    if write_relays == [] do
      Logger.debug("SubscriptionPlanner: no write relays known for #{String.slice(pubkey, 0, 8)}, skipping")
      state
    else
      Enum.reduce(write_relays, state, fn relay_url, acc ->
        current = Map.get(acc.relay_pubkeys, relay_url, MapSet.new())

        if MapSet.member?(current, pubkey) do
          acc
        else
          connect_and_subscribe(relay_url, [pubkey], acc)
        end
      end)
    end
  end

  defp get_write_relays_for_pubkey(pubkey) do
    Repo.all(
      from ur in UserRelays,
        join: r in Info,
        on: ur.relay_id == r.id,
        where: ur.pubkey == ^pubkey and ur.purpose in [:w, :rw],
        select: r.url
    )
  end

  defp connect_and_subscribe(relay_url, pubkeys, state) do
    current = Map.get(state.relay_pubkeys, relay_url, MapSet.new())
    new_pubkeys = Enum.reject(pubkeys, &MapSet.member?(current, &1))

    if new_pubkeys == [] do
      state
    else
      case Relay.maybe_connect_relays([relay_url]) do
        {:ok, _} ->
          case send_sub(relay_url, new_pubkeys) do
            :ok ->
              updated = MapSet.union(current, MapSet.new(new_pubkeys))
              %{state | relay_pubkeys: Map.put(state.relay_pubkeys, relay_url, updated)}

            :error ->
              state
          end

        {:error, reason} ->
          Logger.warning("SubscriptionPlanner: could not connect to #{relay_url}: #{inspect(reason)}")
          state
      end
    end
  end

  defp send_sub(relay_url, pubkeys) do
    since = Notes.since_for_filter(kinds: @feed_kinds, authors: pubkeys)
    limit = Notes.default_limit()

    case Subscription.new(authors: pubkeys, kinds: @feed_kinds, since: since, limit: limit) do
      {:ok, sub} ->
        case NostrEx.send_sub(sub, send_via: [relay_url]) do
          result when result in [:ok] or (is_tuple(result) and elem(result, 0) == :ok) ->
            Logger.info("SubscriptionPlanner: opened sub on #{relay_url} for #{length(pubkeys)} pubkey(s)")
            :ok

          {:error, reason} ->
            Logger.error("SubscriptionPlanner: failed to open sub on #{relay_url}: #{inspect(reason)}")
            :error
        end

      {:error, reason} ->
        Logger.error("SubscriptionPlanner: failed to create subscription: #{inspect(reason)}")
        :error
    end
  end
end
