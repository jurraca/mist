defmodule Mist.Relay do
  @moduledoc """
  The Relay context.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Mist.Repo

  alias Mist.Relay.Info
  alias Mist.Relay.Metadata

  @connect_timeout 5_000

  # Socket-level reconnect policy: a dead relay gets 5 consecutive
  # attempts with 1s..60s jittered backoff (~2-3 minutes of trying) before
  # the socket gives up and unregisters itself. NostrEx's default is
  # :infinity, which hammers dead relays forever.
  @connect_opts [max_attempts: 5, backoff_min: 1_000, backoff_max: 60_000]

  @doc """
  Options passed to every `NostrEx.connect/2` call made by the app.
  """
  def connect_opts, do: @connect_opts

  @doc """
  Returns the list of relays with preloaded metadata.

  ## Examples

      iex> list_relays()
      [%Info{}, ...]

  """
  def list_relays do
    Repo.all(Info) |> Repo.preload(:metadata)
  end

  @doc """
  Ensure the given relay URLs are connected, connecting those that are not.

  Connections are attempted concurrently. Returns `{:ok, connected_urls,
  failed_urls}` — `connected_urls` is the subset of the input that is
  connected afterwards (previously connected plus newly connected);
  `failed_urls` is the subset that failed to connect this call (so the
  caller can back off/blacklist them). Failures are also logged.
  """
  def maybe_connect_relays(relay_list) do
    {connected, not_connected} = connected(relay_list)
    {newly_connected, newly_failed} = connect_relays(not_connected)
    {:ok, connected ++ newly_connected, newly_failed}
  end

  @doc """
  Connect to the given relay URLs concurrently.

  Returns `{connected_urls, failed_urls}`. Tasks are started with
  `Task.Supervisor.async_nolink/2`: a raising or hanging connect (e.g. a
  GenServer.call timeout inside NostrEx) must never propagate an exit into
  the calling GenServer (SubManager).
  """
  def connect_relays(relay_list) when is_list(relay_list) do
    tasks =
      Enum.map(relay_list, fn url ->
        {url, Task.Supervisor.async_nolink(Mist.TaskSupervisor, fn ->
          # NostrEx.connect/1 does an internal GenServer.call that can exit
          # on connection refused / TLS failure. Catch it so the Task
          # terminates normally (no OTP error log) and yield_many sees a
          # clean {:ok, {:error, _}} instead of {:exit, _}.
          try do
            NostrEx.connect(url, connect_opts())
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end
        end)}
      end)

    url_by_ref = Map.new(tasks, fn {url, task} -> {task.ref, url} end)

    {connected, failed} =
      tasks
      |> Enum.map(fn {_url, task} -> task end)
      |> Task.yield_many(timeout: @connect_timeout)
      |> Enum.reduce({[], []}, fn {task, result}, {conn, fail} ->
        url = Map.fetch!(url_by_ref, task.ref)

        case result do
          {:ok, {:ok, _name}} ->
            {[url | conn], fail}

          {:ok, {:error, reason}} ->
            Logger.warning("Relay.connect: could not connect to #{url}: #{inspect(reason)}")
            {conn, [url | fail]}

          {:exit, reason} ->
            Logger.warning("Relay.connect: connect to #{url} crashed: #{inspect(reason)}")
            {conn, [url | fail]}

          nil ->
            Task.shutdown(task, :brutal_kill)
            Logger.warning("Relay.connect: connect to #{url} timed out")
            {conn, [url | fail]}
        end
      end)

    {Enum.reverse(connected), Enum.reverse(failed)}
  end

  def connected(relay_list) do
    registered = NostrEx.RelayManager.registered_names()
    Enum.split_with(relay_list, fn relay -> relay_name(relay) in registered end)
  end

  @doc """
  Normalizes a relay URL to the name NostrEx registers it under (the host).
  """
  def relay_name(relay_url) when is_binary(relay_url) do
    case URI.parse(relay_url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> relay_url
    end
  end

  @doc """
  Gets a single relay.

  Raises `Ecto.NoResultsError` if the Relay does not exist.

  ## Examples

      iex> get_relay!(123)
      %Info{}

      iex> get_relay!(456)
      ** (Ecto.NoResultsError)

  """
  def get_relay!(id), do: Repo.get!(Info, id)

  @doc """
  Creates a relay.

  ## Examples

      iex> create_relay(%{field: value})
      {:ok, %Info{}}

      iex> create_relay(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_relay(attrs \\ %{}) do
    %Info{}
    |> Info.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a relay by its URL or creates a new one if it doesn't exist.

  ## Examples

      iex> get_or_create_relay("wss://example.com", %{field: value})
      {:ok, %Info{}}

      iex> get_or_create_relay("wss://example.com", %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def get_or_create_relay(url, attrs \\ %{}) do
    url = String.trim(url, "/")
    case Repo.get_by(Info, url: url) do
      nil -> attrs |> Map.merge(%{"url" => url}) |> create_relay()
      relay -> {:ok, relay}
    end
  end

  @doc """
  Gets a relay by URL. Returns `{:ok, relay}` if found, `{:error, :not_found}` otherwise.
  """
  def get_relay_by_url(url) do
    url = String.trim(url, "/")
    case Repo.get_by(Info, url: url) do
      nil -> {:error, :not_found}
      relay -> {:ok, relay}
    end
  end

  def create_or_update_relay(url, attrs \\ %{}) do
    url = String.trim(url, "/")
    case get_or_create_relay(url) do
      {:ok, relay} ->
        case upsert_metadata(relay, attrs) do
          {:ok, _metadata} -> {:ok, relay}
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Updates a relay.

  ## Examples

      iex> update_relay(relay, %{field: new_value})
      {:ok, %Info{}}

      iex> update_relay(relay, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_relay(%Info{} = relay, attrs) do
    relay
    |> Info.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a relay.

  ## Examples

      iex> delete_relay(relay)
      {:ok, %Info{}}

      iex> delete_relay(relay)
      {:error, %Ecto.Changeset{}}

  """
  def delete_relay(%Info{} = relay) do
    Repo.delete(relay)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking relay changes.

  ## Examples

      iex> change_relay(relay)
      %Ecto.Changeset{data: %Info{}}

  """
  def change_relay(%Info{} = relay, attrs \\ %{}) do
    Info.changeset(relay, attrs)
  end

  def get_relay_if_fresh(url) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600)
    query =
      from r in Info,
        join: m in Metadata,
        on: m.relay_id == r.id,
        where: r.url == ^url and m.updated_at > ^one_hour_ago,
        preload: [metadata: m]

    Repo.one(query)
  end

  defp upsert_metadata(%Info{} = relay, attrs) do
    metadata_attrs = Map.merge(attrs, %{"relay_id" => relay.id})

    %Metadata{}
    |> Metadata.changeset(metadata_attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :description, :banner, :icon, :pubkey, :contact, :supported_nips, :software, :version, :updated_at]},
      conflict_target: :relay_id
    )
  end
end
