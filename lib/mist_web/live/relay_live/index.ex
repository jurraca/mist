defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  require Logger

  alias Mist.Relay
  alias NostrEx.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "My Relays")
      |> refresh_relay_assigns()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:fetch_relay_info, {id, state}}, socket) do
    lv_pid = self()

    Task.Supervisor.start_child(Mist.TaskSupervisor, fn ->
      result = Relay.Info.get(state.url)
      send(lv_pid, {:relay_info_result, id, state, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:relay_info_result, id, state, {:ok, info}}, socket) do
    if is_map(info) do
      Relay.create_or_update_relay(state.url, info)
      updated_relays =
        Map.update(socket.assigns.relays, id, state, fn x -> %{x | relay_info: info} end)
      {:noreply, assign(socket, :relays, updated_relays)}
    else
      Logger.warning("Could not decode relay info data")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:relay_info_result, id, state, {:error, _reason}}, socket) do
    updated_relays =
      Map.update(socket.assigns.relays, id, state, fn x ->
        %{x | relay_info: %{"status" => "unavailable"}}
      end)

    {:noreply, assign(socket, :relays, updated_relays)}
  end

  @impl true
  def handle_info({MistWeb.RelayLive.FormComponent, :saved}, socket) do
    {:noreply, refresh_relay_assigns(socket)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Relay")
    |> assign(:relay, %{})
    |> assign(:live_action, :new)
  end

  defp apply_action(socket, _, _params) do
    socket
  end

  @impl true
  def handle_event("connect", %{"url" => url}, socket) do
    case NostrEx.connect(url) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:info, "Connected to #{url}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:error, "Could not connect: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("disconnect", %{"url" => url}, socket) do
    RelayManager.disconnect(url)

    {:noreply,
     socket
     |> refresh_relay_assigns()
     |> put_flash(:info, "Disconnected from #{url}")}
  end

  @impl true
  def handle_event("delete", %{"url" => url}, socket) do
    case Relay.get_or_create_relay(url) do
      {:ok, relay} ->
        if MapSet.member?(MapSet.new(NostrEx.list_relays()), url) do
          RelayManager.disconnect(url)
        end

        Relay.delete_relay(relay)

        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:info, "Removed #{url}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not find relay")}
    end
  end

  defp refresh_relay_assigns(socket) do
    relay_list = get_relay_states()
    relay_map = Map.new(relay_list, &{&1.id, &1})

    for {id, state} <- relay_map do
      if is_nil(state.relay_info) do
        send(self(), {:fetch_relay_info, {id, state}})
      end
    end

    assign(socket, :relays, relay_map)
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
