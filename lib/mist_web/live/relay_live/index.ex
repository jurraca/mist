defmodule MistWeb.RelayLive.Index do
  use MistWeb, :live_view

  on_mount {MistWeb.LiveIdentity, :require_identity}

  require Logger

  alias Mist.Relay
  alias Mist.Relay.Metadata

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "My Relays")
      |> assign(:pending_info_ids, MapSet.new())
      |> refresh_relay_assigns()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, url, socket) do
    {:noreply,
     socket
     |> assign(:current_path, URI.parse(url).path)
     |> apply_action(socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:fetch_relay_info, {id, state}}, socket) do
    lv_pid = self()

    Task.Supervisor.start_child(Mist.TaskSupervisor, fn ->
      result = Metadata.get(state.url)
      send(lv_pid, {:relay_info_result, id, state, result})
    end)

    pending = MapSet.put(socket.assigns.pending_info_ids, id)
    {:noreply, assign(socket, :pending_info_ids, pending)}
  end

  @impl true
  def handle_info({:relay_info_result, id, state, {:ok, info}}, socket) do
    pending = MapSet.delete(socket.assigns.pending_info_ids, id)

    if is_map(info) do
      Relay.create_or_update_relay(state.url, info)
      updated_relays =
        Map.update(socket.assigns.relays, id, state, fn x -> %{x | relay_info: info} end)
      {:noreply, socket |> assign(:pending_info_ids, pending) |> assign(:relays, updated_relays)}
    else
      Logger.warning("Could not decode relay info data")
      {:noreply, assign(socket, :pending_info_ids, pending)}
    end
  end

  @impl true
  def handle_info({:relay_info_result, id, state, {:error, _reason}}, socket) do
    pending = MapSet.delete(socket.assigns.pending_info_ids, id)

    updated_relays =
      Map.update(socket.assigns.relays, id, state, fn x ->
        %{x | relay_info: %{"status" => "unavailable"}}
      end)

    {:noreply, socket |> assign(:pending_info_ids, pending) |> assign(:relays, updated_relays)}
  end

  @impl true
  def handle_info({MistWeb.RelayLive.FormComponent, :saved}, socket) do
    {:noreply, refresh_relay_assigns(socket)}
  end

  @impl true
  def handle_info({:identity_switched, _pubkey}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Relay")
    |> assign(:relay, %{})
    |> assign(:live_action, :new)
  end

  defp apply_action(socket, _, _params) do
    socket
  end

  @impl true
  def handle_event("connect", %{"url" => url}, socket) do
    case NostrEx.connect(url, Relay.connect_opts()) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:info, "Connected to #{url}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:error, "Could not connect: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("disconnect", %{"url" => url}, socket) do
    NostrEx.disconnect(url)

    {:noreply,
     socket
     |> refresh_relay_assigns()
     |> put_flash(:info, "Disconnected from #{url}")}
  end

  @impl true
  def handle_event("delete", %{"url" => url}, socket) do
    case Relay.get_relay_by_url(url) do
      {:ok, relay} ->
        if MapSet.member?(MapSet.new(NostrEx.list_relays()), Relay.relay_name(url)) do
          NostrEx.disconnect(url)
        end

        Relay.delete_relay(relay)

        {:noreply,
         socket
         |> refresh_relay_assigns()
         |> put_flash(:info, "Removed #{url}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not find relay")}
    end
  end

  defp refresh_relay_assigns(socket) do
    relay_list = get_relay_states()
    relay_map = Map.new(relay_list, &{&1.id, &1})
    pending = Map.get(socket.assigns, :pending_info_ids, MapSet.new())

    new_pending =
      Enum.reduce(relay_map, pending, fn {id, state}, acc ->
        if is_nil(state.relay_info) and not MapSet.member?(acc, id) do
          send(self(), {:fetch_relay_info, {id, state}})
          MapSet.put(acc, id)
        else
          acc
        end
      end)

    socket
    |> assign(:relays, relay_map)
    |> assign(:pending_info_ids, new_pending)
  end

  defp get_relay_states() do
    db_relays = Relay.list_relays()
    connected_urls = NostrEx.list_relays() |> MapSet.new()
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600)

    Enum.map(db_relays, fn relay ->
      relay_info =
        case relay.metadata do
          nil -> nil
          %Metadata{} = meta -> info_to_display_map(meta)
        end

      needs_fetch = is_nil(relay.metadata) || stale_metadata?(relay.metadata, one_hour_ago)

      %Relay.Status{
        id: "relay-#{relay.id}",
        relay_info: if(needs_fetch, do: nil, else: relay_info),
        relay_name: relay.name || relay.url,
        url: relay.url,
        connected?: MapSet.member?(connected_urls, Relay.relay_name(relay.url))
      }
    end)
  end

  defp stale_metadata?(%Metadata{updated_at: updated_at}, one_hour_ago) do
    DateTime.compare(updated_at, one_hour_ago) == :lt
  end

  defp info_to_display_map(%Metadata{} = meta) do
    %{
      "name" => meta.name,
      "description" => meta.description,
      "version" => meta.version,
      "software" => meta.software,
      "supported_nips" => meta.supported_nips,
      "pubkey" => meta.pubkey,
      "contact" => meta.contact
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
