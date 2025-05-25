
defmodule MistWeb.ProfileLive.Manage do
  use MistWeb, :live_view
  alias Mist.{Profile, Nostr.Keys, Nostr.Signer}
  alias Nostr.Event

  @impl true
  def mount(_params, _session, socket) do
    case Keys.get_private_key() do
      {:ok, _priv_key} ->
        {:ok, pubkey} = Keys.derive_public_key()
        profile = Profile.get_or_create_profile(pubkey)

        {:ok,
         assign(socket,
           pubkey: pubkey,
           profile: profile,
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

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Private key error: #{reason}")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
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
         :ok <- Nostrbase.send_event(event),
         {:ok, profile} <- Profile.update_profile(socket.assigns.profile, params) do
      {:noreply,
       socket
       |> assign(profile: profile)
       |> put_flash(:info, "Profile updated")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update profile: #{inspect(reason)}")}
    end
  end
end
