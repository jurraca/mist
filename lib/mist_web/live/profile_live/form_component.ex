defmodule MistWeb.ProfileLive.FormComponent do
  use MistWeb, :live_component

  alias Mist.Profile

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage profile records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="profile-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >

        <:actions>
          <.button phx-disable-with="Saving...">Save Profile</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{profile: profile} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Profile.change_profile(profile))
     end)}
  end

  @impl true
  def handle_event("validate", %{"profile" => profile_params}, socket) do
    changeset = Profile.change_profile(socket.assigns.profile, profile_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"profile" => profile_params}, socket) do
    save_profile(socket, socket.assigns.action, profile_params)
  end

  defp save_profile(socket, :edit, profile_params) do
    case Profile.update_profile(socket.assigns.profile, profile_params) do
      {:ok, profile} ->
        notify_parent({:saved, profile})

        {:noreply,
         socket
         |> put_flash(:info, "Profile updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_profile(socket, :new, profile_params) do
    case Profile.create_profile(profile_params) do
      {:ok, profile} ->
        notify_parent({:saved, profile})

        {:noreply,
         socket
         |> put_flash(:info, "Profile created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
