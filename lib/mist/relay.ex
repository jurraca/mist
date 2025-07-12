defmodule Mist.Relay do
  @moduledoc """
  The Relay context.
  """

  import Ecto.Query, warn: false
  alias Mist.Repo

  alias Mist.Relay.Relay

  @doc """
  Returns the list of relays.

  ## Examples

      iex> list_relays()
      [%Relay{}, ...]

  """
  def list_relays do
    Repo.all(Relay)
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
    |> Enum.map(fn relay_url -> Task.async(fn -> NostrEx.add_relay(relay_url) end) end)
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
      %Relay{}

      iex> get_relay!(456)
      ** (Ecto.NoResultsError)

  """
  def get_relay!(id), do: Repo.get!(Relay, id)

  @doc """
  Creates a relay.

  ## Examples

      iex> create_relay(%{field: value})
      {:ok, %Relay{}}

      iex> create_relay(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_relay(attrs \\ %{}) do
    %Relay{}
    |> Relay.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a relay by its URL or creates a new one if it doesn't exist.

  ## Examples

      iex> get_or_create_relay("wss://example.com", %{field: value})
      {:ok, %Relay{}}

      iex> get_or_create_relay("wss://example.com", %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def get_or_create_relay(url, attrs \\ %{}) do
    url = String.trim(url, "/")
    case Repo.get_by(Relay, url: url) do
      nil -> attrs |> Map.merge(%{"url" => url}) |> create_relay()
      relay -> {:ok, relay}
    end
  end

  def create_or_update_relay(url, attrs \\ %{}) do
    url = String.trim(url, "/")
    attrs = Map.merge(%{"url" => url}, attrs)
    case Repo.get_by(Relay, url: url) do
      nil -> attrs |> Map.merge(%{"url" => url}) |> create_relay()
      relay -> update_relay(relay, attrs)
    end
  end

  @doc """
  Updates a relay.

  ## Examples

      iex> update_relay(relay, %{field: new_value})
      {:ok, %Relay{}}

      iex> update_relay(relay, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_relay(%Relay{} = relay, attrs) do
    relay
    |> Relay.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a relay.

  ## Examples

      iex> delete_relay(relay)
      {:ok, %Relay{}}

      iex> delete_relay(relay)
      {:error, %Ecto.Changeset{}}

  """
  def delete_relay(%Relay{} = relay) do
    Repo.delete(relay)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking relay changes.

  ## Examples

      iex> change_relay(relay)
      %Ecto.Changeset{data: %Relay{}}

  """
  def change_relay(%Relay{} = relay, attrs \\ %{}) do
    Relay.changeset(relay, attrs)
  end


  def query_relay_info(url) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600)
    query = from r in Relay,
      where: r.url == ^url and r.updated_at > ^one_hour_ago
    Repo.one(query)
  end
end
