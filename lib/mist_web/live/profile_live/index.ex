defmodule MistWeb.ProfileLive.Index do
  use MistWeb, :live_view

  alias Mist.Profile

  @impl true
  def mount(_params, _session, socket) do
    {:ok, 
      socket
      |> stream(:profiles, Profile.list_profiles())
      |> assign(:nprofile_form, to_form(%{"nprofile" => ""}))
      |> assign(:parsed_profile, nil)}
  end

  @impl true
  def handle_event("parse_nprofile", %{"nprofile" => input}, socket) do
    case parse_identifier(input) do
      {:ok, %{pubkey: pubkey, relays: relays} = profile_data} ->
        npub = Nostr.Bech32.hex_to_npub(pubkey)
        relays_str = Enum.join(relays, ", ")
        profile = profile_data
        |> Map.put(:npub, npub)
        |> Map.put(:relays, relays_str)
        
        {:noreply, assign(socket, :parsed_profile, profile)}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp parse_identifier("nprofile" <> _rest = input) do
    Mist.Nostr.NIP19.parse(input)
  end

  defp parse_identifier("npub" <> _rest = input) do
    case Nostr.Bech32.npub_to_hex(input) do
      pubkey when is_binary(pubkey) ->
        {:ok, %{pubkey: pubkey, npub: input, relays: []}}
      _ ->
        {:error, "Invalid npub format"}
    end
  end

  defp parse_identifier(input) when byte_size(input) == 64 do
    # Assume raw hex pubkey if 64 chars
    npub = Nostr.Bech32.hex_to_npub(input) 
    {:ok, %{pubkey: input, npub: npub, relays: []}}
  end

  defp parse_identifier(_) do
    {:error, "Invalid format - please provide nprofile, npub, or hex pubkey"}
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
