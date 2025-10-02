defmodule MistWeb.ProfileLive.ManageFollows do
  use MistWeb, :live_view

  alias Mist.{Profile, Nostr.Keys}

  @impl true
  def mount(_params, _session, socket) do
    case Keys.get_private_key() do
      {:ok, _priv_key} ->
        {:ok, pubkey} = Keys.derive_public_key()
        {:ok, profile} = Profile.get_or_create_profile(pubkey)

        follows = Profile.get_follows_with_privacy(profile.id)
        lists = Profile.get_follow_lists(profile.id)

        {:ok,
         socket
         |> assign(
           pubkey: pubkey,
           profile: profile,
           follows: follows,
           lists: lists,
           selected_follows: MapSet.new(),
           show_new_list_form: false,
           new_list_form: to_form(%{"name" => "", "description" => "", "color" => "#10b981"}),
           has_local_keypair: true
         )}

      {:error, _reason} ->
        {:ok, assign(socket, has_local_keypair: false)}
    end
  end

  @impl true
  def handle_event("toggle_visibility", %{"follow_id" => follow_id}, socket) do
    follow_id = String.to_integer(follow_id)

    follow = Enum.find(socket.assigns.follows, fn f -> f.follow_id == follow_id end)

    if follow do
      Profile.toggle_follow_visibility(follow_id, !follow.is_public)

      updated_follows =
        Enum.map(socket.assigns.follows, fn f ->
          if f.follow_id == follow_id, do: %{f | is_public: !f.is_public}, else: f
        end)

      {:noreply, assign(socket, follows: updated_follows)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_select", %{"follow_id" => follow_id}, socket) do
    follow_id = String.to_integer(follow_id)

    selected =
      if MapSet.member?(socket.assigns.selected_follows, follow_id) do
        MapSet.delete(socket.assigns.selected_follows, follow_id)
      else
        MapSet.put(socket.assigns.selected_follows, follow_id)
      end

    {:noreply, assign(socket, selected_follows: selected)}
  end

  @impl true
  def handle_event("show_new_list_form", _params, socket) do
    {:noreply, assign(socket, show_new_list_form: true)}
  end

  @impl true
  def handle_event("cancel_new_list", _params, socket) do
    {:noreply,
     socket
     |> assign(show_new_list_form: false)
     |> assign(new_list_form: to_form(%{"name" => "", "description" => "", "color" => "#10b981"}))}
  end

  @impl true
  def handle_event("create_list", %{"name" => name, "description" => description, "color" => color}, socket) do
    case Profile.create_follow_list(socket.assigns.profile.id, %{
           name: name,
           description: description,
           color: color
         }) do
      {:ok, list} ->
        {:noreply,
         socket
         |> assign(lists: socket.assigns.lists ++ [list])
         |> assign(show_new_list_form: false)
         |> assign(new_list_form: to_form(%{"name" => "", "description" => "", "color" => "#10b981"}))
         |> put_flash(:info, "List created successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create list")}
    end
  end

  @impl true
  def handle_event("delete_list", %{"list_id" => list_id}, socket) do
    list_id = String.to_integer(list_id)

    case Profile.delete_follow_list(list_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(lists: Enum.reject(socket.assigns.lists, fn l -> l.id == list_id end))
         |> put_flash(:info, "List deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete list")}
    end
  end

  @impl true
  def handle_event("add_to_list", %{"list_id" => list_id}, socket) do
    list_id = String.to_integer(list_id)

    Enum.each(socket.assigns.selected_follows, fn follow_id ->
      Profile.add_follow_to_list(follow_id, list_id)
    end)

    {:noreply,
     socket
     |> assign(selected_follows: MapSet.new())
     |> put_flash(:info, "Added to list")}
  end

  @impl true
  def handle_event("publish_follow_list", _params, socket) do
    case Profile.publish_public_follow_list(socket.assigns.pubkey) do
      {:ok, _event} ->
        {:noreply, put_flash(socket, :info, "Published follow list to relays")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to publish: #{inspect(reason)}")}
    end
  end
end
