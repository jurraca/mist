defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  alias Mist.Relay
  alias Nostrbase.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    relay_states = RelayManager.get_states()
    |> Enum.map(fn state -> 
      %Relay.Status{id: state.url, relay_info: %{"status" => "loading"}, url: state.url}
    end)

    socket = socket
    |> stream(:relays, relay_states)
    |> assign(:page_title, "Listing Relays")

    # Fetch relay info asynchronously for each relay
    for state <- relay_states do
      send(self(), {:fetch_relay_info, state})
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:fetch_relay_info, state}, socket) do
    case Relay.Info.get(state.url) do
      {:ok, info} -> 
        {:noreply, stream_insert(socket, :relays, %{state | relay_info: info})}
      {:error, _reason} -> 
        {:noreply, stream_insert(socket, :relays, %{state | relay_info: %{"status" => "unavailable"}})}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, socket}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Relay")
    |> assign(:relay, Relay.get_relay!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Relay")
    |> assign(:relay, %Relay.Relay{})
  end

  @impl true
  def handle_info({MistWeb.RelayLive.FormComponent, {:saved, relay}}, socket) do
    {:noreply, stream_insert(socket, :relays, relay)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    relay = Relay.get_relay!(id)
    RelayManager.disconnect(relay.name)

    {:noreply, stream_delete(socket, :relays, relay)}
  end
end
