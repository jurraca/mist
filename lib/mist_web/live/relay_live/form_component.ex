defmodule MistWeb.RelayLive.FormComponent do
  use MistWeb, :live_component

  alias Mist.Relay

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Add a relay URL to your saved relays.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="relay-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <.input field={@form[:url]} type="text" label="URL" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Relay</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{relay: _relay} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
        to_form(%{"url" => nil})
     end)}
  end

  @impl true
  def handle_event("save", %{"url" => url}, socket) do
    case Relay.get_or_create_relay(url) do
      {:ok, _relay} ->
        notify_parent(:saved)

        {:noreply,
         socket
         |> put_flash(:info, "Relay saved successfully.")
         |> push_patch(to: socket.assigns.patch)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not save relay.")
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
