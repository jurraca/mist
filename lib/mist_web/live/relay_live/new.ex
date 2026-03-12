defmodule MistWeb.RelayLive.New do
  use MistWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "New Relay")
     }
  end
end
