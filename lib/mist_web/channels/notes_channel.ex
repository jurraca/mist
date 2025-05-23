defmodule MistWeb.NotesChannel do
  use MistWeb, :channel
  alias Mist.Profile
  alias Mist.Nostr.Dispatcher

  @impl true
  def join("notes", _params, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("subscribe_follows", %{"pubkey" => pubkey}, socket) do
    with {:ok, profile} <- Profile.get_by_pubkey(pubkey) |> then(&{:ok, &1}),
         followed <- profile |> Profile.preload(:following) |> Map.get(:following) do
      pubkeys = Enum.map(followed, & &1.pubkey)
      Nostrbase.send_subscription([authors: pubkeys, kinds: [1]], [])
      {:reply, {:ok, %{followed_count: length(followed)}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "Profile not found"}}, socket}
    end
  end

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (notes:lobby).
  @impl true
  def handle_in("shout", payload, socket) do
    broadcast(socket, "shout", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(event, socket) do
    broadcast!(socket, "notes", event)
    {:noreply, socket}
  end
end