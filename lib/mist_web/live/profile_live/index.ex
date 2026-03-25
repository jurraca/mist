defmodule MistWeb.ProfileLive.Index do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.Profile
  alias Mist.Nostr.NIP19
  alias Nostr.Bech32

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mist.PubSub, "profiles")

    case Profile.get_my_profile() do
      {:ok, profile} ->
        follows = Map.get(profile, :following)

        {:ok,
         socket
         |> stream(:profiles, follows || [])
         |> assign(:search_form, to_form(%{"search_term" => ""}))
         |> assign(:parsed_profile, nil)}

      {:error, _reason} ->
        {:ok,
         socket
         |> stream(:profiles, [])
         |> assign(:search_form, to_form(%{"search_term" => ""}))
         |> assign(:parsed_profile, nil)}
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
          {:noreply,
           socket
           |> stream_insert(:profiles, profile)
           |> assign(:parsed_profile, nil)}

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
  def handle_event("follow", %{"pubkey" => pubkey}, socket) do
    my_pubkey = :persistent_term.get(:my_profile_pubkey, nil)

    if is_nil(my_pubkey) do
      {:noreply, put_flash(socket, :error, "No keypair configured — cannot follow profiles")}
    else
      case Profile.follow_profile(my_pubkey, pubkey) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Followed successfully")}

        {:ok, _} ->
          {:noreply, put_flash(socket, :info, "Followed successfully")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to follow: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_info(%Profile.Profile{} = profile, socket) do
    {:noreply, stream_insert(socket, :profiles, profile)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp search(%{pubkey: pubkey, relays: relays} = profile_data) when relays != [] do
    case Profile.get_by_pubkey(profile_data.pubkey) do
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

  defp search(%{pubkey: _pubkey} = data), do: {:ok, data}

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply,
     socket
     |> assign(:current_path, URI.parse(url).path)
     |> assign(:page_title, "Profiles")
     |> assign(:profiles, [])}
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
