defmodule Mist.Profile do
  @moduledoc """
  The Profile context.
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
    case Repo.get_by(Profile, pubkey: pubkey) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
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
    case Relay.maybe_connect_relays([h]) do
      {:ok, connected} ->
        if h in connected do
          SubManager.subscribe_profiles([pubkey], send_via: [h])
        else
          case Relay.connected(relays) do
            {[], _} -> {:error, :no_relays_connected}
            {fallbacks, _} -> SubManager.subscribe_profiles([pubkey], send_via: fallbacks)
          end
        end
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
         {:ok, followed} <- get_or_create_profile(followed_pubkey),
         {:ok, follow} <-
           (%Follows{}
            |> Follows.changeset(%{follower_id: follower.id, followed_id: followed.id})
            |> Repo.insert()) do
      Phoenix.PubSub.broadcast(Mist.PubSub, "profile:new_follow", {:new_follow, followed_pubkey})
      {:ok, follow}
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
    with {:ok, follower} <- get_or_create_profile(follower_pubkey) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      tag_data =
        for %Nostr.Tag{type: type, data: pubkey, info: info}
            when type in [:p, "p"] and is_binary(pubkey) and pubkey != "" <- new_follows do
          relay =
            case info do
              [r | _] when is_binary(r) and r != "" -> r
              _ -> nil
            end

          petname =
            case info do
              [_, p | _] when is_binary(p) and p != "" -> p
              _ -> nil
            end

          {pubkey, relay, petname}
        end

      tag_data = Enum.uniq_by(tag_data, &elem(&1, 0))

      if tag_data == [] do
        {:ok, []}
      else
        pubkeys = Enum.map(tag_data, &elem(&1, 0))

        profile_rows =
          Enum.map(tag_data, fn {pubkey, relay, _petname} ->
            base = %{pubkey: pubkey, inserted_at: now, updated_at: now}
            if relay, do: Map.put(base, :relay, relay), else: base
          end)

        Repo.insert_all(Profile, profile_rows, on_conflict: :nothing)

        pubkey_to_id =
          from(p in Profile, where: p.pubkey in ^pubkeys, select: {p.pubkey, p.id})
          |> Repo.all()
          |> Map.new()

        follow_rows =
          for {pubkey, _relay, petname} <- tag_data,
              id = Map.get(pubkey_to_id, pubkey),
              not is_nil(id) do
            %{
              follower_id: follower.id,
              followed_id: id,
              petname: petname,
              inserted_at: now,
              updated_at: now
            }
          end

        Repo.insert_all(Follows, follow_rows, on_conflict: :nothing)
      end
    end
  end

  def add_user_relays(pubkey, user_relays) do
    case get_by_pubkey(pubkey) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, profile} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        parsed_tags =
          user_relays
          |> Enum.map(fn tag ->
            case parse_tag_url_purpose(tag) do
              {:ok, parsed} -> parsed
              _err -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        relay_urls = Enum.map(parsed_tags, & &1.relay_url) |> Enum.uniq()

        relay_rows =
          relay_urls
          |> Enum.map(fn url ->
            uri = URI.parse(url)
            %{url: url, name: uri.host, inserted_at: now, updated_at: now}
          end)

        Repo.insert_all(Mist.Relay.Info, relay_rows, on_conflict: :nothing, conflict_target: :url)

        relay_map =
          from(r in Mist.Relay.Info, where: r.url in ^relay_urls)
          |> Repo.all()
          |> Map.new(fn r -> {r.url, r.id} end)

        relay_attrs =
          parsed_tags
          |> Enum.map(fn %{relay_url: url, purpose: purpose} ->
            case Map.get(relay_map, url) do
              nil -> nil
              relay_id ->
                %{
                  relay_id: relay_id,
                  purpose: purpose,
                  pubkey: profile.pubkey,
                  profile_id: profile.id,
                  inserted_at: now,
                  updated_at: now
                }
            end
          end)
          |> Enum.reject(&is_nil/1)

        Repo.insert_all(UserRelays, relay_attrs, on_conflict: {:replace_all_except, [:id]})
    end
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
    changeset = Profile.changeset(%Profile{}, attrs)
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:pubkey]) do
      {:ok, %Profile{id: nil}} -> get_by_pubkey(pubkey)
      {:ok, profile} -> {:ok, profile}
      {:error, _} = error -> error
    end
  end

  def create_or_update_profile(%{user: pubkey} = attrs) do
    create_or_update_profile(Map.merge(attrs, %{"pubkey" => pubkey}))
  end

  def create_or_update_profile(%{"pubkey" => _pubkey} = attrs) do
    changeset = Profile.changeset(%Profile{}, attrs)
    Repo.insert(changeset,
      on_conflict: {:replace, [:name, :about, :picture, :display_name, :website, :banner, :bot, :relay, :updated_at]},
      conflict_target: [:pubkey],
      returning: true
    )
  end

  def create_profile_from_tag(%Nostr.Tag{data: pubkey, info: info}) do
    {profile_attrs, follow_attrs} =
      case info do
        [relay, petname] -> {%{pubkey: pubkey, relay: relay}, %{petname: petname}}
        [relay] -> {%{pubkey: pubkey, relay: relay}, %{}}
        _ -> {%{pubkey: pubkey}, %{}}
      end

    changeset = Profile.changeset(%Profile{}, profile_attrs)
    profile_result =
      Repo.insert(changeset,
        on_conflict: {:replace, [:name, :about, :picture, :display_name, :website, :banner, :bot, :relay, :updated_at]},
        conflict_target: [:pubkey],
        returning: true
      )

    case profile_result do
      {:ok, profile} -> {:ok, Map.put(profile, :_follow_attrs, follow_attrs)}
      error -> error
    end
  end

  def get_user_relays(pubkey) do
    query =
      from ur in UserRelays,
        join: p in Profile,
        on: ur.profile_id == p.id,
        join: r in Mist.Relay.Info,
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
      on: ur.profile_id == p.id,
      where: is_nil(ur.id) and is_nil(p.relay)
    )
    |> Repo.all()
  end

  @doc """
  Returns pubkeys from the given list that still have no relay entries.
  """
  def fetch_pubkeys_without_relays(pubkeys) when is_list(pubkeys) do
    from(p in Profile,
      left_join: ur in Mist.Profile.UserRelays,
      on: ur.profile_id == p.id,
      where: p.pubkey in ^pubkeys and is_nil(ur.id) and is_nil(p.relay),
      select: p.pubkey
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
  def update_relay_check_timestamp(pubkey) when is_binary(pubkey) do
    from(p in Profile, where: p.pubkey == ^pubkey)
    |> Repo.update_all(set: [relay_last_checked: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  def update_relay_check_timestamp(pubkeys) when is_list(pubkeys) do
    from(p in Profile, where: p.pubkey in ^pubkeys)
    |> Repo.update_all(set: [relay_last_checked: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  @doc """
  Takes a list of profiles such as a follow list, and returns a map of relays to the profiles that write to them. This is useful to aggregate filters by relay before subscribing.
  """
  def get_write_relays_by_relay(follows) when is_list(follows) do
    follow_pubkeys = Enum.map(follows, & &1.pubkey)

    query =
      from ur in Mist.Profile.UserRelays,
        join: p in Mist.Profile.Profile,
        on: ur.profile_id == p.id,
        join: r in Mist.Relay.Info,
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

  # Privacy Management Functions

  @doc """
  Publish a kind 3 follow list event with only public follows.
  """
  def publish_public_follow_list(profile_pubkey) do
    alias Mist.Nostr.Signer

    case get_by_pubkey(profile_pubkey) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, profile} ->
        public_follows = get_public_follows_with_petname(profile.id)

        tags =
          Enum.map(public_follows, fn %{profile: followed, petname: petname} ->
            relay = followed.relay || ""
            petname = petname || followed.name || ""
            ["p", followed.pubkey, relay, petname]
          end)

        event_params =
          NostrEx.create_event(3, %{
            content: "",
            tags: tags
          })

        with {:ok, event} <- Signer.sign_event(event_params),
             :ok <- NostrEx.send_event(event) do
          {:ok, event}
        else
          error -> error
        end
    end
  end

  @doc """
  Toggle the visibility of a follow relationship.
  """
  def toggle_follow_visibility(follow_id, is_public) do
    from(f in Follows, where: f.id == ^follow_id)
    |> Repo.update_all(set: [is_public: is_public])
  end

  @doc """
  Get all public follows for a profile.
  """
  def get_public_follows(profile_id) do
    from(f in Follows,
      join: followed in Profile,
      on: f.followed_id == followed.id,
      where: f.follower_id == ^profile_id and f.is_public == true,
      select: followed
    )
    |> Repo.all()
  end

  def get_public_follows_with_petname(profile_id) do
    from(f in Follows,
      join: followed in Profile,
      on: f.followed_id == followed.id,
      where: f.follower_id == ^profile_id and f.is_public == true,
      select: %{profile: followed, petname: f.petname}
    )
    |> Repo.all()
  end

  @doc """
  Get all private follows for a profile.
  """
  def get_private_follows(profile_id) do
    from(f in Follows,
      join: followed in Profile,
      on: f.followed_id == followed.id,
      where: f.follower_id == ^profile_id and f.is_public == false,
      select: followed
    )
    |> Repo.all()
  end

  @doc """
  Get all follows for a profile with their privacy status.
  """
  def get_follows_with_privacy(profile_id) do
    from(f in Follows,
      join: followed in Profile,
      on: f.followed_id == followed.id,
      where: f.follower_id == ^profile_id,
      select: %{
        follow_id: f.id,
        profile: followed,
        is_public: f.is_public,
        notes: f.notes
      }
    )
    |> Repo.all()
  end

  # Follow List Management Functions

  alias Mist.Profile.{FollowList, FollowListMembers}

  @doc """
  Create a new follow list for a profile.
  """
  def create_follow_list(profile_id, attrs) do
    attrs = Map.put(attrs, :profile_id, profile_id)

    %FollowList{}
    |> FollowList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a follow list.
  """
  def update_follow_list(list_id, attrs) do
    FollowList
    |> Repo.get(list_id)
    |> case do
      nil -> {:error, :not_found}
      list -> list |> FollowList.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Delete a follow list.
  """
  def delete_follow_list(list_id) do
    FollowList
    |> Repo.get(list_id)
    |> case do
      nil -> {:error, :not_found}
      list -> Repo.delete(list)
    end
  end

  @doc """
  Get all lists for a profile.
  """
  def get_follow_lists(profile_id) do
    from(fl in FollowList,
      where: fl.profile_id == ^profile_id,
      order_by: [asc: fl.name]
    )
    |> Repo.all()
  end

  @doc """
  Add a follow to a list.
  """
  def add_follow_to_list(follow_id, list_id) do
    %FollowListMembers{}
    |> FollowListMembers.changeset(%{follow_id: follow_id, follow_list_id: list_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Remove a follow from a list.
  """
  def remove_follow_from_list(follow_id, list_id) do
    from(m in FollowListMembers,
      where: m.follow_id == ^follow_id and m.follow_list_id == ^list_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Get all follows in a list with profile information.
  """
  def get_follows_in_list(list_id) do
    from(m in FollowListMembers,
      join: f in Follows,
      on: m.follow_id == f.id,
      join: p in Profile,
      on: f.followed_id == p.id,
      where: m.follow_list_id == ^list_id,
      select: %{follow_id: f.id, profile: p}
    )
    |> Repo.all()
  end

  @doc """
  Get pubkeys of all follows in a list (for subscription filtering).
  """
  def get_pubkeys_in_list(list_id) do
    from(m in FollowListMembers,
      join: f in Follows,
      on: m.follow_id == f.id,
      join: p in Profile,
      on: f.followed_id == p.id,
      where: m.follow_list_id == ^list_id,
      select: p.pubkey
    )
    |> Repo.all()
  end

  @doc """
  Get all lists that a follow belongs to.
  """
  def get_lists_for_follow(follow_id) do
    from(m in FollowListMembers,
      join: l in FollowList,
      on: m.follow_list_id == l.id,
      where: m.follow_id == ^follow_id,
      select: l
    )
    |> Repo.all()
  end

  @doc """
  Get a follow list with its member count.
  """
  def get_list_with_count(list_id) do
    query =
      from fl in FollowList,
        left_join: m in FollowListMembers,
        on: m.follow_list_id == fl.id,
        where: fl.id == ^list_id,
        group_by: fl.id,
        select: {fl, count(m.id)}

    case Repo.one(query) do
      nil -> {:error, :not_found}
      {list, count} -> {:ok, Map.put(list, :member_count, count)}
    end
  end

  defp parse_tag_url_purpose(%{data: url}) when url in [nil, ""] do
    {:error, "empty relay URL in tag"}
  end

  defp parse_tag_url_purpose(%{data: relay_url, info: info}) do
    normalized_url = URI.to_string(URI.parse(relay_url)) |> String.trim("/")
    purpose = translate_rw(info)
    {:ok, %{relay_url: normalized_url, purpose: purpose}}
  end

  defp parse_tag_url_purpose(_tag) do
    {:error, "missing a required key in tag: data or info"}
  end

  defp translate_rw(["read"]), do: :r
  defp translate_rw(["write"]), do: :w
  defp translate_rw(_), do: :rw
end
