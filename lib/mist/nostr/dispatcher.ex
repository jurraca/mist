defmodule Mist.Nostr.Dispatcher do
  use GenServer
  require Logger

  alias Nostr.Event
  alias Mist.Profile
  alias Mist.Repo

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state, {:continue, nil}}
  end

  def subscribe_profile(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_profile, pubkey, opts})
  end

  def subscribe_follows(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_follows, pubkey, opts})
  end

  def subscribe_notes(pubkey, opts \\ []) do
    GenServer.cast(__MODULE__, {:subscribe_notes, pubkey, opts})
  end

  @impl GenServer
  def handle_continue(_arg, state) do
    subscribe_to_follows_events()
    {:noreply, state}
  end

  defp subscribe_to_follows_events do
    with %Profile.Profile{} = my_profile <- Profile.get_my_profile(),
        write_relay_map = Profile.get_write_relays_by_relay(my_profile.following) do

        case write_relay_map |> Map.keys() |> Mist.Relay.maybe_connect_relays() do
          {:ok, _} ->
            sub_ids = Enum.map(write_relay_map, fn {relay_url, authors} ->
              case subscribe_to_relay_for_authors(relay_url, authors) do
                {:ok, sub_id} ->
                  Logger.debug("Subscribed to #{relay_url} for #{length(authors)} authors")
                  sub_id
                {:error, reason} ->
                  Logger.debug(reason)
              end
            end)
            {:ok, sub_ids} 

          {:error, reason} ->
            Logger.debug(reason)
        end
      else
      {:error, _} ->
        Logger.debug("No profile set, skipping follows subscription")
    end
  end

  defp subscribe_to_relay_for_authors(relay_url, authors) do
    filter = [kinds: [0, 10002], authors: authors]
    Nostrbase.send_subscription([filter], send_via: [relay_url])
  end

  @impl GenServer
  def handle_cast({:subscribe_profile, pubkey, opts}, state) do
    Nostrbase.subscribe_profile(pubkey, send_via: opts[:relays])
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:subscribe_follows, pubkey, opts}, state) do
    Nostrbase.subscribe_follows(pubkey, send_via: opts[:relays])
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:subscribe_notes, pubkey, opts}, state) do
    Nostrbase.subscribe_notes(pubkey, send_via: opts[:relays])
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, %Event{kind: 0, pubkey: pubkey} = event}, state) do
    dbg("DISPATCH RECV ")

    with {:ok, content} <- Jason.decode(event.content),
      {:ok, profile} <- content
          |> Map.put("pubkey", pubkey)
          |> Profile.create_profile() do
        Phoenix.PubSub.broadcast(Mist.PubSub, "profiles", profile)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:event, _sub_id, %Event{kind: 10002, pubkey: pubkey, tags: tags} = event}, state) do
    with {count, _} <- Profile.add_user_relays(pubkey, tags),
         true <- count > 0 do
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:event, _sub_id, %Event{kind: 1} = event}, state) do
    topic = "notes"
    # Write to a kind-1-only DB table
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, %Event{kind: 3, pubkey: pubkey, tags: tags} = event}, state) do
    dbg(event)
    topic = "profiles"
    Profile.add_follow_list(tags)
    #Profile.create_profile()
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    dbg(event)
    topic = "events:#{event.kind}"
    # write to a general events table
    Phoenix.PubSub.broadcast(Mist.PubSub, topic, event)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info("EOSE", state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
