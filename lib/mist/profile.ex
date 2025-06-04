defmodule Mist.Profile do
  @moduledoc """
  The Nostr context.
  """

  import Ecto.Query, warn: false
  alias Mist.Repo

  alias Mist.Nostr.Dispatcher
  alias Mist.Profile.{Follows, Profile}
  alias Mist.Relay

  @doc """
  Returns the list of profiles.

  ## Examples

      iex> list_profiles()
      [%Profile{}, ...]

  """
  def list_profiles do
    Repo.all(Profile)
  end

  @doc """
  Gets a single profile.

  Raises `Ecto.NoResultsError` if the Profile does not exist.

  ## Examples

      iex> get_profile!(123)
      %Profile{}

      iex> get_profile!(456)
      ** (Ecto.NoResultsError)

  """
  def get_profile!(id), do: Repo.get!(Profile, id)

  @doc """
  Creates a profile.

  ## Examples

      iex> create_profile(%{field: value})
      {:ok, %Profile{}}

      iex> create_profile(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_profile(attrs \\ %{}) do
    %Profile{}
    |> Profile.changeset(attrs)
    |> Repo.insert()
  end

  def get_by_pubkey(pubkey) do
    Profile
    |> Repo.get_by(pubkey: pubkey)
    |> Repo.preload([:following])
  end

  def sub_via_relays(pubkey, [ h | _ ] = relays) do
    with {:ok, _} <- Relay.maybe_connect_relays([h]) do
      Dispatcher.subscribe_profile(pubkey, send_via: [h])
    else
      {:error, _} ->
        {connected, _} = Relay.connected(relays)
        Dispatcher.subscribe_profile(pubkey, send_via: connected)
      err -> err
    end
  end

  @doc """
  Updates a profile.

  ## Examples

      iex> update_profile(profile, %{field: new_value})
      {:ok, %Profile{}}

      iex> update_profile(profile, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_profile(%Profile{} = profile, attrs) do
    profile
    |> Profile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a profile.

  ## Examples

      iex> delete_profile(profile)
      {:ok, %Profile{}}

      iex> delete_profile(profile)
      {:error, %Ecto.Changeset{}}

  """
  def delete_profile(%Profile{} = profile) do
    Repo.delete(profile)
  end

  def follow_profile(follower_pubkey, followed_pubkey) do
    with {:ok, follower} <- get_or_create_profile(follower_pubkey),
      {:ok, followed} <- get_or_create_profile(followed_pubkey) do

      %Follows{}
      |> Follows.changeset(%{follower_id: follower.id, followed_id: followed.id})
      |> Repo.insert()
    end
  end

  def unfollow_profile(follower_pubkey, followed_pubkey) do
    with {:ok, follower} <- get_by_pubkey(follower_pubkey),
         {:ok, followed} <- get_by_pubkey(followed_pubkey) do

      from(f in Follows,
        where: f.follower_id == ^follower.id and f.followed_id == ^followed.id
      )
      |> Repo.delete_all()
    end
  end

  def set_my_profile(pubkey) do
    with {:ok, profile} <- get_or_create_profile(pubkey) do
      :persistent_term.put(:my_profile_pubkey, pubkey)
      {:ok, profile}
    end
  end

  def get_my_profile do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil -> {:error, :no_profile_set}
      pubkey -> get_by_pubkey(pubkey)
    end
  end

  def fetch_follows(pubkey) do
    Dispatcher.subscribe_follows(pubkey)
    {:ok, pubkey}
  end

  def get_or_create_profile(pubkey) do
    case get_by_pubkey(pubkey) do
      nil -> create_profile(%{pubkey: pubkey})
      profile -> {:ok, profile}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking profile changes.

  ## Examples

      iex> change_profile(profile)
      %Ecto.Changeset{data: %Profile{}}

  """
  def change_profile(%Profile{} = profile, attrs \\ %{}) do
    Profile.changeset(profile, attrs)
  end
end
