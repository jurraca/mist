defmodule MistWeb.ProfileLive.Manage do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.{Profile, Nostr.Keys, Nostr.Signer}

  @impl true
  def mount(_params, _session, socket) do
    has_local_keypair = match?({:ok, _}, Keys.get_private_key())

    empty_form = to_form(%{
      "name" => "",
      "about" => "",
      "picture" => "",
      "display_name" => "",
      "website" => "",
      "banner" => "",
      "bot" => false
    })

    case Profile.get_my_profile() do
      {:ok, profile} when not is_nil(profile) ->
        {:ok,
         assign(socket,
           pubkey: profile.pubkey,
           profile: profile,
           has_local_keypair: has_local_keypair,
           form:
             to_form(%{
               "name" => profile.name || "",
               "about" => profile.about || "",
               "picture" => profile.picture || "",
               "display_name" => profile.display_name || "",
               "website" => profile.website || "",
               "banner" => profile.banner || "",
               "bot" => profile.bot || false
             })
         )}

      _ ->
        {:ok,
         assign(socket,
           pubkey: nil,
           profile: nil,
           has_local_keypair: has_local_keypair,
           form: empty_form
         )}
    end
  end

  @impl true
  def handle_event("generate_keypair", _params, socket) do
    case Secp256k1.keypair(:xonly) do
      {priv_key, pub_key} ->
        priv_key_hex = Base.encode16(priv_key, case: :lower)
        pub_key_hex = Base.encode16(pub_key, case: :lower)

        Application.put_env(:mist, :private_key, priv_key_hex)

        case Profile.get_or_create_profile(pub_key_hex) do
          {:ok, profile} ->
            {:noreply,
             socket
             |> assign(
               pubkey: pub_key_hex,
               profile: profile,
               has_local_keypair: true,
               form: to_form(%{
                 "name" => profile.name || "",
                 "about" => profile.about || "",
                 "picture" => profile.picture || "",
                 "display_name" => profile.display_name || "",
                 "website" => profile.website || "",
                 "banner" => profile.banner || "",
                 "bot" => profile.bot || false
               })
             )
             |> put_flash(:info, "Keypair generated successfully! Your public key: #{pub_key_hex}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create profile: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    if socket.assigns.has_local_keypair do
      content =
        %{
          "name" => params["name"],
          "about" => params["about"],
          "picture" => params["picture"],
          "display_name" => params["display_name"],
          "website" => params["website"],
          "banner" => params["banner"],
          "nip05" => nil
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) || v == "" end)
        |> Map.new()
        |> Jason.encode!()

      with {:ok, unsigned} <- NostrEx.create_event(0, content: content, tags: []),
           {:ok, profile} <- Profile.update_profile(socket.assigns.profile, params),
           {:ok, event} <- Signer.sign_event(unsigned),
           {:ok, _event_id, _failures} <- NostrEx.send_event(event) do
        {:noreply,
         socket
         |> assign(profile: profile)
         |> put_flash(:info, "Profile updated")}
      else
        {:error, reason, _failures} ->
          {:noreply, put_flash(socket, :error, "Failed to update profile: #{inspect(reason)}")}
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update profile: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No private key found. Please configure your private key to create a profile.")}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply, assign(socket, :current_path, URI.parse(url).path)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
