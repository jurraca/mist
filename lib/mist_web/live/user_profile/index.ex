defmodule MistWeb.UserProfile.Index do
  use MistWeb, :live_view

  alias Mist.{Profile, Nostr.Signer}

  @impl true
  def mount(_params, _session, socket) do
    case Profile.get_my_profile() do
      {:ok, profile} ->
        {:ok,
         assign(socket,
           pubkey: profile.pubkey,
           profile: profile,
           form: to_form(%{
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
         |> put_flash(:error, "Failed to get public key: #{reason}")
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
      kind: 0,
      content: content,
      tags: []
    }

    case Signer.sign_event(event_params) do
      {:ok, _event} ->
        # Update local profile with the new data
        profile_attrs = Map.merge(params, %{"pubkey" => socket.assigns.pubkey})

        case Profile.update_profile(socket.assigns.profile, profile_attrs) do
          {:ok, updated_profile} ->
            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> put_flash(:info, "Profile updated successfully and event signed")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:form, to_form(changeset))
             |> put_flash(:error, "Failed to update profile")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to sign event: #{reason}")}
    end
  end

  @impl true
  def handle_event("validate", %{"profile" => profile_params}, socket) do
    form = to_form(profile_params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
