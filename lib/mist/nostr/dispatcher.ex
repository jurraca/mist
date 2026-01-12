defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Mist.Nostr.EventHandler
  alias NostrEx.Subscription

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{active_subscriptions: []}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  def subscribe(%Subscription{} = sub, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe, sub, opts})
  end

  def cancel_all_subscriptions do
    GenServer.cast(__MODULE__, :cancel_all)
  end

  def subscribe_profiles(pubkeys, opts \\ []) do
    pubkeys = if is_list(pubkeys), do: pubkeys, else: [pubkeys]
    filters = [%{kinds: [0, 10002], authors: pubkeys}]
    subscribe(filters, opts)
  end

  def subscribe_follows(pubkey, opts \\ []) do
    filters = [%{kinds: [3], authors: [pubkey]}]
    subscribe(filters, opts)
  end

  def subscribe_notes(pubkey, opts \\ []) do
    filters = [%{kinds: [1], authors: [pubkey]}]
    subscribe(filters, opts)
  end

  def subscribe_all_notes(opts \\ []) do
    filters = [%{kinds: [1, 6, 7, 9735]}]  # Include reactions, boosts, and zaps
    subscribe(filters, opts)
  end

  def subscribe_relay_notes(relay_url, opts \\ []) do
    filters = [%{kinds: [1, 6, 7, 9735]}]  # Include reactions, boosts, and zaps
    subscribe(filters, Keyword.put(opts, :relays, [relay_url]))
  end

  def subscribe_hashtag_notes(hashtag, opts \\ []) do
    # Remove # if present and ensure lowercase
    clean_hashtag = hashtag |> String.replace("#", "") |> String.downcase()
    filters = [%{kinds: [1], "#t": [clean_hashtag]}]
    subscribe(filters, opts)
  end

  def subscribe_follows_notes(pubkeys, opts \\ []) when is_list(pubkeys) do
    filters = [%{kinds: [1, 6, 7, 9735], authors: pubkeys}]  # Include reactions, boosts, and zaps
    subscribe(filters, opts)
  end

  def subscribe_list_notes(list_id, opts \\ []) do
    alias Mist.Profile
    pubkeys = Profile.get_pubkeys_in_list(list_id)
    
    if length(pubkeys) > 0 do
      filters = [%{kinds: [1, 6, 7, 9735], authors: pubkeys}]
      subscribe(filters, opts)
    else
      # If no pubkeys in list, subscribe to nothing (empty subscription)
      Logger.info("List #{list_id} has no follows, subscribing to all notes as fallback")
      subscribe_all_notes(opts)
    end
  end

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    case NostrEx.send_sub(filters, send_via: opts[:relays]) do
      {:ok, sub_id} ->
        Logger.debug("Created subscription #{sub_id} with #{length(filters)} filters")
        {:noreply, %{state | active_subscriptions: [sub_id | state.active_subscriptions]}}
      {:error, reason} ->
        Logger.error("Failed to create subscription: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(:cancel_all, state) do
    Enum.each(state.active_subscriptions, fn sub_id ->
      NostrEx.close_sub(sub_id)
      Logger.debug("Cancelled subscription #{sub_id}")
    end)
    {:noreply, %{state | active_subscriptions: []}}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    Task.start(fn -> EventHandler.process_event(event) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:eose, sub_id, _relay}, state) do
    Logger.info("EOSE for #{sub_id}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end