defmodule MistWeb.RelayLive.FormComponent do
  use MistWeb, :live_component

  alias Mist.Relay

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage relay records in your database.</:subtitle>
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
  def update(%{relay: relay} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Relay.change_relay(relay))
     end)}
  end

  @impl true
  def handle_event("validate", %{"relay" => relay_params}, socket) do
    changeset = Relay.change_relay(socket.assigns.relay, relay_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"relay" => %{"url" => url}}, socket) do
    case Nostrbase.add_relay(url) do
      {:ok, _pid} ->
        {:ok, relay} = Relay.create_relay(%{name: url})
        notify_parent({:saved, relay})

        {:noreply,
         socket
         |> put_flash(:info, "Successfully connected to Relay!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, error} ->
      {:reply,
         %{error: error},
         socket
         |> put_flash(:error, "Relay not created: #{error}")
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
