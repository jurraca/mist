defmodule MistWeb.ProfileLive.Index do
  use MistWeb, :live_view

  alias Mist.Profile

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :profiles, Profile.list_profiles())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Profile")
    |> assign(:profile, Profile.get_profile!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Profile")
    |> assign(:profile, %Profile.Profile{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Profiles")
    |> assign(:profiles, [])
  end

  @impl true
  def handle_info({MistWeb.ProfileLive.FormComponent, {:saved, profile}}, socket) do
    {:noreply, stream_insert(socket, :profiles, profile)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    profile = Profile.get_profile!(id)
    {:ok, _} = Profile.delete_profile(profile)

    {:noreply, stream_delete(socket, :profiles, profile)}
  end
end
