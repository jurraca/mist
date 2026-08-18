defmodule MistWeb.ProfileLive.Show do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.Profile
  alias NostrCore.Bech32

  @impl true
  def handle_params(%{"id" => id}, url, socket) do
    profile = Profile.get_profile!(id)

    npub =
      case Bech32.npub(profile.pubkey) do
        {:ok, npub} -> npub
        _ -> profile.pubkey
      end

    display_name = profile.display_name || profile.name || npub

    {:noreply,
     socket
     |> assign(:current_path, URI.parse(url).path)
     |> assign(:page_title, display_name)
     |> assign(:profile, profile)
     |> assign(:display_name, display_name)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: "/profiles")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
