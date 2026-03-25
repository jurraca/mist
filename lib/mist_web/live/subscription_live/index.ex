defmodule MistWeb.SubscriptionLive.Index do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  alias Mist.Subscriptions
  alias Mist.Subscriptions.Subscription

  @impl true
  def mount(_params, _session, socket) do
    subscriptions = Subscriptions.list_subscriptions()

    {:ok,
     socket
     |> assign(:page_title, "Subscriptions")
     |> assign(:subscriptions, subscriptions)
     |> assign(:editing, nil)
     |> assign(:show_form, false)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply, assign(socket, :current_path, URI.parse(url).path)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    changeset = Subscriptions.change_subscription(%Subscription{})

    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:show_form, true)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    subscription = Subscriptions.get_subscription!(String.to_integer(id))
    changeset = Subscriptions.change_subscription(subscription)

    {:noreply,
     socket
     |> assign(:editing, subscription)
     |> assign(:show_form, true)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:show_form, false)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_event("save", %{"subscription" => params}, socket) do
    params = normalize_params(params)

    result =
      case socket.assigns.editing do
        nil -> Subscriptions.create_subscription(params)
        sub -> Subscriptions.update_subscription(sub, params)
      end

    case result do
      {:ok, _subscription} ->
        subscriptions = Subscriptions.list_subscriptions()

        {:noreply,
         socket
         |> assign(:subscriptions, subscriptions)
         |> assign(:editing, nil)
         |> assign(:show_form, false)
         |> assign(:form, nil)
         |> put_flash(:info, "Subscription saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    subscription = Subscriptions.get_subscription!(String.to_integer(id))
    {:ok, _} = Subscriptions.delete_subscription(subscription)
    subscriptions = Subscriptions.list_subscriptions()

    {:noreply,
     socket
     |> assign(:subscriptions, subscriptions)
     |> put_flash(:info, "Subscription deleted.")}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp normalize_params(params) do
    params
    |> normalize_integer_list("kinds")
    |> normalize_string_list("authors")
    |> normalize_optional_integer("since")
    |> normalize_optional_integer("until")
    |> normalize_optional_integer("limit")
    |> normalize_tags()
  end

  defp normalize_integer_list(params, key) do
    value = Map.get(params, key, "")

    parsed =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn s ->
        case Integer.parse(s) do
          {n, ""} -> [n]
          _ -> []
        end
      end)

    case parsed do
      [] -> Map.put(params, key, nil)
      list -> Map.put(params, key, list)
    end
  end

  defp normalize_string_list(params, key) do
    value = Map.get(params, key, "")

    parsed =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parsed do
      [] -> Map.put(params, key, nil)
      list -> Map.put(params, key, list)
    end
  end

  defp normalize_optional_integer(params, key) do
    value = Map.get(params, key, "")

    case String.trim(value) do
      "" ->
        Map.put(params, key, nil)

      str ->
        case Integer.parse(str) do
          {n, ""} -> Map.put(params, key, n)
          _ -> Map.put(params, key, nil)
        end
    end
  end

  defp normalize_tags(params) do
    raw = Map.get(params, "tags_raw", "")

    tags =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [k, v] ->
            key = String.trim(k)
            val = String.trim(v)

            if key != "" and val != "" do
              existing = Map.get(acc, key, [])
              Map.put(acc, key, existing ++ [val])
            else
              acc
            end

          _ ->
            acc
        end
      end)

    params
    |> Map.delete("tags_raw")
    |> Map.put("tags", if(tags == %{}, do: nil, else: tags))
  end

  defp tags_to_raw(nil), do: ""
  defp tags_to_raw(tags) when is_map(tags) do
    tags
    |> Enum.flat_map(fn {k, vals} ->
      vals |> Enum.map(fn v -> "#{k}: #{v}" end)
    end)
    |> Enum.join("\n")
  end

  defp format_field(nil), do: ""
  defp format_field([]), do: ""
  defp format_field(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_field(val), do: to_string(val)
end
