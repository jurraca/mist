defmodule Mist.Settings do
  @moduledoc """
  Key/value settings store backed by the `settings` table.
  """

  alias Mist.Repo
  require Ecto.Query

  def get(key) when is_binary(key) do
    case Repo.query("SELECT value FROM settings WHERE key = $1", [key]) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  def put(key, value) when is_binary(key) and is_binary(value) do
    case Repo.query(
           "INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = $2",
           [key, value]
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  def delete(key) when is_binary(key) do
    case Repo.query("DELETE FROM settings WHERE key = $1", [key]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
