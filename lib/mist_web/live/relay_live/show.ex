defmodule MistWeb.RelayLive.Show do
  use MistWeb, :live_view

  alias Mist.Nostr

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:relay, Nostr.get_relay!(id))}
  end

  defp page_title(:show), do: "Show Relay"
  defp page_title(:edit), do: "Edit Relay"
end
