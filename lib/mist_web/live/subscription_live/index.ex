defmodule MistWeb.SubscriptionLive.Index do
  use MistWeb, :live_view

  alias Mist.Nostr.Dispatcher
  alias NostrEx.RelayManager

  @impl true
  def mount(_params, _session, socket) do
    relay_states = RelayManager.get_states()

    {:ok,
     socket
     |> assign(:page_title, "Subscriptions")
     |> assign(:relays, relay_states)
     |> assign(:selected_relay, nil)
     |> assign(:kinds, "1")
     |> assign(:authors, "")
     |> assign(:hashtag, "")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_relay", %{"relay" => relay_url}, socket) do
    {:noreply, assign(socket, :selected_relay, relay_url)}
  end

  @impl true
  def handle_event("update_filters", params, socket) do
    socket =
      socket
      |> assign(:kinds, Map.get(params, "kinds", socket.assigns.kinds))
      |> assign(:authors, Map.get(params, "authors", socket.assigns.authors))
      |> assign(:hashtag, Map.get(params, "hashtag", socket.assigns.hashtag))

    {:noreply, socket}
  end

  @impl true
  def handle_event("subscribe", _params, socket) do
    filters = build_filters(socket.assigns)
    opts = build_opts(socket.assigns)
    sub = NostrEx.create_sub(filters)

    Dispatcher.subscribe(sub, opts)

    {:noreply, put_flash(socket, :info, "Subscription started")}
  end

  @impl true
  def handle_event("cancel_all", _params, socket) do
    Dispatcher.cancel_all_subscriptions()
    {:noreply, put_flash(socket, :info, "All subscriptions cancelled")}
  end

  defp build_filters(assigns) do
    base_filter = [] 

    base_filter =
      case parse_kinds(assigns.kinds) do
        [] -> base_filter
        kinds -> Keyword.put(base_filter, :kinds, kinds)
      end

    base_filter =
      case parse_authors(assigns.authors) do
        [] -> base_filter
        authors -> Keyword.put(base_filter, :authors, authors)
      end

    base_filter =
      case String.trim(assigns.hashtag) do
        "" -> base_filter
        tag -> Keyword.put(base_filter, :"#t", [String.downcase(tag)])
      end

    [base_filter]
  end

  defp build_opts(assigns) do
    case assigns.selected_relay do
      nil -> []
      "" -> []
      relay -> [relays: [relay]]
    end
  end

  defp parse_kinds(kinds_string) do
    kinds_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  rescue
    _ -> []
  end

  defp parse_authors(authors_string) do
    authors_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
