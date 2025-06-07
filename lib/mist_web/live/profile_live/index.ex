defmodule MistWeb.ProfileLive.Index do
  use MistWeb, :live_view

  alias Mist.Profile
  alias Mist.Nostr.NIP19
  alias Nostr.{Bech32, Event}

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mist.PubSub, "profiles")
    with {:ok, profile} <- Profile.get_my_profile(),
        follows <- Map.get(profile, :following) do

        {:ok,
         socket
         |> stream(:profiles, follows || [])
         |> assign(:search_form, to_form(%{"search_term" => ""}))
         |> assign(:parsed_profile, nil)}
    else
      {:error, reason} ->
      {:ok, socket
         |> stream(:profiles, [])
         |> assign(:search_form, to_form(%{"search_term" => ""}))
         |> assign(:parsed_profile, nil)
        }
     end
  end

  @impl true
  def handle_event("search", %{"search_term" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search_term" => input}, socket) do
    with {:ok, profile_data} <- parse_identifier(input) do
      npub = Bech32.hex_to_npub(profile_data.pubkey)

      case search(profile_data) do
        {:ok, profile, :local} ->
          {:noreply, stream_insert(socket, :profiles, profile)}

        {:ok, %{pubkey: pubkey, relays: relays}} when relays != [] ->
          {:noreply,
           assign(socket, :parsed_profile, %{
             pubkey: pubkey,
             npub: npub,
             relays: Enum.join(relays, ", ")
           })}

        {:ok, %{pubkey: pubkey}} ->
          {:noreply,
           socket
           |> put_flash(:error, "Profile exists but no relays specified to fetch data")
           |> assign(:parsed_profile, %{pubkey: pubkey, npub: npub, relays: []})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    profile = Profile.get_profile!(id)
    {:ok, _} = Profile.delete_profile(profile)

    {:noreply, stream_delete(socket, :profiles, profile)}
  end

  @impl true
  def handle_event("follow", %{"pubkey" => pubkey}, socket) do
    :persistent_term.get(:my_profile_pubkey, nil)
    |> Profile.follow_profile(pubkey)

    {:noreply, socket}
  end

  @impl true
  def handle_info(%Profile.Profile{} = profile, socket) do
    dbg("Profile Liveview RECVD kind 0")
    {:noreply, stream_insert(socket, :profiles, profile)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp search(%{pubkey: pubkey, relays: relays} = profile_data) when relays != [] do
    case find_local_profile(profile_data.pubkey) do
      {:ok, profile} ->
        {:ok, profile, :local}

      {:error, :not_found} ->
        case Profile.sub_via_relays(pubkey, relays) do
          :ok -> {:ok, profile_data}
          err -> err
        end

      error ->
        error
    end
  end

  defp search(%{pubkey: _pubkey, relays: []} = data), do: {:ok, data}

  defp find_local_profile(pubkey) do
    case Profile.get_by_pubkey(pubkey) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
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
    |> assign(:page_title, "Profiles")
    |> assign(:profiles, [])
  end

  defp parse_identifier("nprofile" <> _rest = input) do
    NIP19.parse(input)
  end

  defp parse_identifier("npub" <> _rest = input) do
    case Bech32.npub_to_hex(input) do
      pubkey when is_binary(pubkey) ->
        {:ok, %{pubkey: pubkey, npub: input, relays: []}}

      _ ->
        {:error, "Invalid npub format"}
    end
  end

  defp parse_identifier(input) when byte_size(input) == 64 do
    npub = Bech32.hex_to_npub(input)
    {:ok, %{pubkey: input, npub: npub, relays: []}}
  end

  defp parse_identifier(_) do
    {:error, "Invalid format - please provide nprofile, npub, or hex pubkey"}
  end
end
