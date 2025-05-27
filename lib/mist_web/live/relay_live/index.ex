defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  alias Mist.Relay
  alias Nostrbase.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    relay_map = get_relay_states() |> Map.new(&{&1.id, &1})

    socket = socket
    |> assign(:relays, relay_map)
    |> assign(:page_title, "My Relays")

    for {id, state} <- relay_map do
      send(self(), {:fetch_relay_info, {id, state}})
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
        updated_relays = Map.update(socket.assigns.relays, id, state, fn x -> %{x | relay_info: info} end)
        {:noreply, assign(socket, :relays, updated_relays)}
      {:error, _reason} ->
        updated_relays = Map.update(socket.assigns.relays, id, state, fn x -> %{x | relay_info: %{"status" => "unavailable"}} end)
        {:noreply, assign(socket, :relays, updated_relays)}
    end
  end

  @impl true
  def handle_info({MistWeb.RelayLive.FormComponent, :saved}, socket) do
    relay_states = get_relay_states()
    {:noreply, assign(socket, :relays, relay_states)}
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
  def handle_event("delete", %{"name" => name}, socket) do
    RelayManager.disconnect(name)

    relay_states = get_relay_states()
    {:noreply, assign(socket, :relays, relay_states)}
  end

  defp get_relay_states() do
    RelayManager.get_states()
    |> Enum.map(fn state ->
      %Relay.Status{id: state.name, relay_name: state.name, relay_info: %{"status" => "loading"}, url: state.url}
    end)
  end
end
