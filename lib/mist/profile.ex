defmodule Mist.Profile do
  @moduledoc """
  The Nostr context.
  """

  import Ecto.Query, warn: false
  alias Mist.Repo

  alias Mist.Nostr.Dispatcher
  alias Mist.Profile.{Follows, Profile, UserRelays}
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
  Get a single profile by its pubkey.
  """
  def get_by_pubkey(pubkey) do
    Profile
    |> Repo.get_by(pubkey: pubkey)
  end

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

  def sub_via_relays(pubkey, [h | _] = relays) do
    with {:ok, _} <- Relay.maybe_connect_relays([h]) do
      Dispatcher.subscribe_profiles([pubkey], send_via: [h])
    else
      {:error, _} ->
        {connected, _} = Relay.connected(relays)
        Dispatcher.subscribe_profiles([pubkey], send_via: connected)

      err ->
        err
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

  def fetch_follows(pubkey) do
    Dispatcher.subscribe_follows(pubkey)
    {:ok, pubkey}
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

  def add_follow_list(follower_pubkey, new_follows) do
    with {:ok, follower} <- get_or_create_profile(follower_pubkey),
         followed_list <-
           Enum.map(
             new_follows,
             fn follow_tag ->
               case create_profile_from_tag(follow_tag) do
                 {:ok, profile} -> profile
                 _ -> nil
               end
             end
           )
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq_by(& &1.id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      follow_list_attrs =
        Enum.map(followed_list, fn profile ->
          %{follower_id: follower.id,
            followed_id: profile.id,
            inserted_at: now,
            updated_at: now}
        end)

      Repo.insert_all(Follows, follow_list_attrs, on_conflict: :nothing)
    end
  end

  def add_user_relays(pubkey, user_relays) do
    profile = get_by_pubkey(pubkey)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    relay_attrs =
      user_relays
      |> Enum.map(fn tag ->
        case UserRelays.parse_tag(tag) do
          {:ok, parsed} ->
            parsed
            |> Map.put(:pubkey, profile.pubkey)
            |> Map.put(:inserted_at, now)
            |> Map.put(:updated_at, now)

          _err ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Repo.insert_all(UserRelays, relay_attrs, on_conflict: {:replace_all_except, [:id]})
  end

  def get_my_profile do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil -> {:error, :no_profile_set}
      pubkey -> {:ok, Profile |> Repo.get_by(pubkey: pubkey) |> Repo.preload([:following])}
    end
  end

  def get_or_create_profile(pubkey) when is_binary(pubkey) do
    get_or_create_profile(%{"pubkey" => pubkey})
  end

  def get_or_create_profile(%{"pubkey" => pubkey} = attrs) do
    case get_by_pubkey(pubkey) do
      nil -> create_profile(attrs)
      profile -> {:ok, profile}
    end
  end

  def create_or_update_profile(%{user: pubkey} = attrs) do
    create_or_update_profile(Map.merge(attrs, %{"pubkey" => pubkey}))
  end

  def create_or_update_profile(%{"pubkey" => pubkey} = attrs) do
    case get_by_pubkey(pubkey) do
      nil -> create_profile(attrs)
      profile -> update_profile(profile, attrs)
    end
  end

  def create_profile_from_tag(%Nostr.Tag{data: pubkey, info: info}) do
    attrs = %{pubkey: pubkey}

    attrs =
      case info do
        [relay, petname] -> Map.merge(attrs, %{relay: relay, petname: petname})
        [relay] -> Map.put(attrs, :relay, relay)
        _ -> attrs
      end

    case get_by_pubkey(pubkey) do
      nil -> create_profile(attrs)
      profile -> update_profile(profile, attrs)
    end
  end

  def get_user_relays(pubkey) do
    query =
      from ur in UserRelays,
        join: p in Profile,
        on: ur.pubkey_id == p.id,
        join: r in Mist.Relay.Relay,
        on: ur.relay_id == r.id,
        where: p.pubkey == ^pubkey,
        select: %{relay: r.url, purpose: ur.purpose}

    Repo.all(query)
  end

  @doc """
  Fetches profiles that do not have any UserRelays assigned or `relay` items in their profile.
  """
  def fetch_profiles_without_relays do
    from(p in Profile,
      left_join: ur in Mist.Profile.UserRelays,
      on: ur.pubkey_id == p.id,
      where: is_nil(ur.id) and is_nil(p.relay)
    )
    |> Repo.all()
  end

  @doc """
  Fetches profiles for relay discovery, prioritizing those never checked or checked long ago.
  """
  def fetch_profiles_for_relay_discovery(limit \\ 50) do
    # Get profiles that haven't been checked in the last 24 hours or never checked
    cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
    
    from(p in Profile,
      where: is_nil(p.relay_last_checked) or p.relay_last_checked < ^cutoff,
      order_by: [asc: p.relay_last_checked],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Updates the last relay check timestamp for a profile.
  """
  def update_relay_check_timestamp(pubkey) do
    from(p in Profile, where: p.pubkey == ^pubkey)
    |> Repo.update_all(set: [relay_last_checked: DateTime.utc_now()])
  end

  @doc """
  Takes a list of profiles such as a follow list, and returns a map of relays to the profiles that write to them. This is useful to aggregate filters by relay before subscribing.
  """
  def get_write_relays_by_relay(follows) when is_list(follows) do
    follow_pubkeys = Enum.map(follows, & &1.pubkey)

    query =
      from ur in Mist.Profile.UserRelays,
        join: p in Mist.Profile.Profile,
        on: ur.pubkey == p.pubkey,
        join: r in Mist.Relay.Relay,
        on: ur.relay_id == r.id,
        where: p.pubkey in ^follow_pubkeys and ur.purpose in [:w, :rw],
        select: %{relay: r.url, pubkey: p.pubkey}

    Repo.all(query)
    |> Enum.uniq()
    |> Enum.group_by(& &1.relay, & &1.pubkey)
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
