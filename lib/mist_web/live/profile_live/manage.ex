defmodule MistWeb.ProfileLive.Manage do
  use MistWeb, :live_view
  alias Mist.{Profile, Nostr.Keys, Nostr.Signer}

  @impl true
  def mount(_params, _session, socket) do
    case Keys.get_private_key() do
      {:ok, _priv_key} ->
        {:ok, pubkey} = Keys.derive_public_key()
        {:ok, profile} = Profile.get_or_create_profile(pubkey)

        {:ok,
         assign(socket,
           pubkey: pubkey,
           profile: profile,
           has_local_keypair: true,
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

      {:error, _reason} ->
        {:ok,
         assign(socket,
           pubkey: nil,
           profile: nil,
           has_local_keypair: false,
           form:
             to_form(%{
               "name" => "",
               "about" => "",
               "picture" => "",
               "display_name" => "",
               "website" => "",
               "banner" => "",
               "bot" => false
             })
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

      error ->
        {:noreply, put_flash(socket, :error, "Failed to generate keypair: #{inspect(error)}")}
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

      event_params = %{
        content: content,
        kind: 0,
        tags: []
      }

      with {:ok, event} <- Signer.sign_event(event_params),
           :ok <- NostrEx.send_event(event),
           {:ok, profile} <- Profile.update_profile(socket.assigns.profile, params) do
        {:noreply,
         socket
         |> assign(profile: profile)
         |> put_flash(:info, "Profile updated")}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update profile: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No private key found. Please configure your private key to create a profile.")}
    end
  end
end
