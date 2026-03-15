defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  require Logger

  alias Mist.Relay
  alias NostrEx.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    relay_list = get_relay_states()
    relay_map = Map.new(relay_list, &{&1.id, &1})

    socket =
      socket
      |> assign(:relays, relay_map)
      |> assign(:page_title, "My Relays")

    for {id, state} <- relay_map do
      if is_nil(state.relay_info) do
        send(self(), {:fetch_relay_info, {id, state}})
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:fetch_relay_info, {id, state}}, socket) do
    case Relay.Info.get(state.url) do
      {:ok, info} ->
        if is_map(info) do
            Relay.create_or_update_relay(state.url, info)
            updated_relays =
              Map.update(socket.assigns.relays, id, state, fn x -> %{x | relay_info: info} end)
              {:noreply, assign(socket, :relays, updated_relays)}
        else
            Logger.warning("Could not decode relay info data")
            {:noreply, socket}
        end

      {:error, _reason} ->
        updated_relays =
          Map.update(socket.assigns.relays, id, state, fn x ->
            %{x | relay_info: %{"status" => "unavailable"}}
          end)

        {:noreply, assign(socket, :relays, updated_relays)}
    end
  end

  @impl true
  def handle_info({MistWeb.RelayLive.FormComponent, :saved}, socket) do
    relay_list = get_relay_states()
    relay_map = Map.new(relay_list, &{&1.id, &1})

    for {id, state} <- relay_map do
      if is_nil(state.relay_info) do
        send(self(), {:fetch_relay_info, {id, state}})
      end
    end

    {:noreply, assign(socket, :relays, relay_map)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Relay")
    |> assign(:relay, %Relay.Status{})
    |> assign(:live_action, :new)
  end

  defp apply_action(socket, _, _params) do
    socket
  end

  @impl true
  def handle_event("connect", %{"url" => url}, socket) do
    case NostrEx.connect(url) do
      {:ok, _pid} ->
        relay_list = get_relay_states()
        relay_map = Map.new(relay_list, &{&1.id, &1})

        {:noreply,
         socket
         |> assign(:relays, relay_map)
         |> put_flash(:info, "Connected to #{url}")}

      {:error, reason} ->
        relay_list = get_relay_states()
        relay_map = Map.new(relay_list, &{&1.id, &1})

        {:noreply,
         socket
         |> assign(:relays, relay_map)
         |> put_flash(:error, "Could not connect: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("disconnect", %{"url" => url}, socket) do
    RelayManager.disconnect(url)

    relay_list = get_relay_states()
    relay_map = Map.new(relay_list, &{&1.id, &1})

    {:noreply,
     socket
     |> assign(:relays, relay_map)
     |> put_flash(:info, "Disconnected from #{url}")}
  end

  defp get_relay_states() do
    db_relays = Relay.list_relays()
    connected_urls = NostrEx.list_relays() |> MapSet.new()

    Enum.map(db_relays, fn relay ->
      relay_info =
        case Relay.get_relay_if_fresh(relay.url) do
          nil -> nil
          %Relay.Info{} = info -> info_to_display_map(info)
        end

      %Relay.Status{
        id: "relay-#{relay.id}",
        relay_info: relay_info,
        relay_name: relay.name || relay.url,
        url: relay.url,
        connected?: MapSet.member?(connected_urls, relay.url)
      }
    end)
  end

  defp info_to_display_map(%Relay.Info{} = info) do
    %{
      "name" => info.name,
      "description" => info.description,
      "version" => info.version,
      "software" => info.software,
      "supported_nips" => info.supported_nips,
      "pubkey" => info.pubkey,
      "contact" => info.contact
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
