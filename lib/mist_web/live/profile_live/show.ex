defmodule MistWeb.ProfileLive.Show do
  use MistWeb, :live_view

  alias Mist.Profile
  alias Nostr.Bech32

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    profile = Profile.get_profile!(id)

    npub =
      case Bech32.hex_to_npub(profile.pubkey) do
        {:ok, npub} -> npub
        _ -> profile.pubkey
      end

    display_name = profile.display_name || profile.name || npub

    {:noreply,
     socket
     |> assign(:page_title, display_name)
     |> assign(:profile, profile)
     |> assign(:display_name, display_name)}
  end
end
