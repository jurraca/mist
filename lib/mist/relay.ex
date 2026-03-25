defmodule Mist.Relay do
  @moduledoc """
  The Relay context.
  """

  import Ecto.Query, warn: false
  alias Mist.Repo

  alias Mist.Relay.Info
  alias Mist.Relay.Metadata

  @doc """
  Returns the list of relays with preloaded metadata.

  ## Examples

      iex> list_relays()
      [%Info{}, ...]

  """
  def list_relays do
    Repo.all(Info) |> Repo.preload(:metadata)
  end

  def maybe_connect_relays(relay_list) do
    {connected, not_connected} = connected(relay_list)

    if not_connected != [] do
      case connect_relays(not_connected) do
         {:ok, _} -> {:ok, relay_list}
         {:error, reason} -> {:error, "could not connect to #{Enum.join(reason, ", ")}"}
      end
    else
      {:ok, connected}
    end
  end

  def connect_relays(relay_list) when is_list(relay_list) do
    relay_list
    |> Enum.map(fn relay_url -> Task.async(fn -> NostrEx.connect(relay_url) end) end)
    |> Task.yield_many(timeout: 3_000)
    |> Enum.map(fn {task, output} ->
      output || Task.ignore(task)
    end)
    |> Mist.Utils.collect()
  end

  def connected(relay_list) do
    registered = NostrEx.RelayManager.registered_names()
    Enum.split_with(relay_list, fn relay -> relay in registered end)
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
          {:ok, _metadata} -> {:ok, Repo.preload(relay, :metadata, force: true)}
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
