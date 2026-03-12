defmodule MistWeb.NoteLive.FormComponent do
  use MistWeb, :live_component

  alias Mist.Nostr.Event

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Write</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="note-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:content]} type="textarea" label="Content" />
        <:actions>
          <.button phx-disable-with="Publishing...">Publish Note</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{note: note} = assigns, socket) do
    changeset = Event.change_note(note)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"note" => note_params}, socket) do
    changeset =
      %Event{}
      |> Event.change_note(note_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"note" => %{"content" => content}}, socket) do
    trimmed_params = %{"content" => String.trim(content)}
    changeset = Event.change_note(%Event{}, trimmed_params)

    if changeset.valid? do
      case Event.publish(trimmed_params["content"]) do
        {:ok, event_map, :no_relays} ->
          notify_parent({:saved, event_map})

          {:noreply,
           socket
           |> put_flash(:warning, "Note saved locally but no relays are connected to broadcast it.")
           |> push_patch(to: socket.assigns.patch)}

        {:ok, event_map, {:relay_error, reason}} ->
          notify_parent({:saved, event_map})

          {:noreply,
           socket
           |> put_flash(:warning, "Note saved locally but relay broadcast failed: #{inspect(reason)}")
           |> push_patch(to: socket.assigns.patch)}

        {:ok, event_map} ->
          notify_parent({:saved, event_map})

          {:noreply,
           socket
           |> put_flash(:info, "Note published successfully")
           |> push_patch(to: socket.assigns.patch)}

        {:error, reason} ->
          message =
            cond do
              is_binary(reason) && String.contains?(reason, "private") ->
                "No signing key configured. Please set up your private key to publish notes."

              is_binary(reason) ->
                "Failed to publish note: #{reason}"

              true ->
                "Failed to publish note: #{inspect(reason)}"
            end

          {:noreply, socket |> put_flash(:error, message)}
      end
    else
      {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "note"))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
