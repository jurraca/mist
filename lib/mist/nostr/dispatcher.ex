defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Mist.Notes
  alias Mist.Nostr.EventHandler
  alias NostrEx.Subscription

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{active_subscriptions: %{}}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  def subscribe(filters, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe, filters, opts})
  end

  def subscribe_with_name(name, filters, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_named, name, filters, opts})
  end

  def cancel_named_subscription(name) do
    GenServer.cast(__MODULE__, {:cancel_named, name})
  end

  def subscribe_profiles(pubkeys, opts \\ []) when is_list(pubkeys) do
    kinds = [0, 10002]
    since = Notes.since_for_filter(kinds: kinds, authors: pubkeys)
    limit = Notes.default_limit()

    case Subscription.new(authors: pubkeys, kinds: kinds, since: since, limit: limit) do
      {:ok, sub} -> subscribe(sub, opts)
      {:error, reason} -> Logger.error("Failed to create profile subscription: #{inspect(reason)}")
    end
  end

  def subscribe_follows(pubkey) when is_binary(pubkey) do
    kinds = [3]
    since = Notes.since_for_filter(kinds: kinds, authors: [pubkey])
    limit = Notes.default_limit()

    case Subscription.new(authors: [pubkey], kinds: kinds, since: since, limit: limit) do
      {:ok, sub} -> subscribe(sub, [])
      {:error, reason} -> Logger.error("Failed to create follows subscription: #{inspect(reason)}")
    end
  end

  def cancel_all_subscriptions do
    GenServer.cast(__MODULE__, :cancel_all)
  end

  @impl GenServer
  def handle_cast({:subscribe, filters, opts}, state) do
    {sub, send_opts} = prepare_subscription(filters, opts)

    case NostrEx.send_sub(sub, send_opts) do
      :ok ->
        Logger.debug("Created subscription #{sub.id}")
        subs = Map.put(state.active_subscriptions, sub.id, sub.id)
        {:noreply, %{state | active_subscriptions: subs}}

      {:error, reason} ->
        Logger.error("Failed to create subscription: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:subscribe_named, name, filters, opts}, state) do
    state = cancel_named_sub(state, name)
    {sub, send_opts} = prepare_subscription(filters, opts)

    case NostrEx.send_sub(sub, send_opts) do
      :ok ->
        Logger.debug("Created named subscription #{name} -> #{sub.id}")
        subs = Map.put(state.active_subscriptions, name, sub.id)
        {:noreply, %{state | active_subscriptions: subs}}

      {:error, reason} ->
        Logger.error("Failed to create named subscription #{name}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:cancel_named, name}, state) do
    {:noreply, cancel_named_sub(state, name)}
  end

  @impl GenServer
  def handle_cast(:cancel_all, state) do
    Enum.each(state.active_subscriptions, fn {_name, sub_id} ->
      NostrEx.close_sub(sub_id)
      Logger.debug("Cancelled subscription #{sub_id}")
    end)
    {:noreply, %{state | active_subscriptions: %{}}}
  end

  defp cancel_named_sub(state, name) do
    case Map.get(state.active_subscriptions, name) do
      nil ->
        state

      sub_id ->
        NostrEx.close_sub(sub_id)
        Logger.debug("Cancelled named subscription #{name} -> #{sub_id}")
        %{state | active_subscriptions: Map.delete(state.active_subscriptions, name)}
    end
  end

  defp prepare_subscription(%NostrEx.Subscription{} = sub, opts) do
    relay_opt = opts[:relays] || opts[:send_via]
    send_opts = if relay_opt, do: [send_via: relay_opt], else: []
    {sub, send_opts}
  end

  defp prepare_subscription(filters, opts) when is_list(filters) do
    {:ok, sub} = NostrEx.create_sub(filters)
    prepare_subscription(sub, opts)
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
