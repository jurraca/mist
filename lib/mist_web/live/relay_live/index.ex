defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  alias Mist.Relay
  alias Nostrbase.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :relays, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    relays = RelayManager.get_states()
      |> Enum.with_index(fn x, i ->
          case Relay.Info.get(x.url) do
            {:ok, info} -> Map.merge(%Relay.Status{id: i, relay_info: info}, x) |> dbg()
            {:error, _reason} -> Map.merge(%Relay.Status{id: i, relay_info: "not available"}, x)
          end
        end)

    socket
    |> assign(:page_title, "Listing Relays")
    |> assign(:relays, relays)
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
