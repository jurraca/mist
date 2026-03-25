defmodule Mist.Notes do
  import Ecto.Query

  alias Mist.Nostr.Event
  alias Mist.Profile.Profile

  @default_since_window Application.compile_env(:mist, :subscription_since_window, 86_400)
  @default_limit Application.compile_env(:mist, :subscription_limit, 500)

  def publish(content) when is_binary(content) do
    alias Mist.Nostr.{Signer, EventHandler}

    with {:ok, pubkey} <- Signer.get_public_key(),
         {:ok, unsigned} <- NostrEx.create_event(1, content: content, pubkey: pubkey),
         {:ok, signed} <- Signer.sign_event(unsigned) do
      connected_relays = NostrEx.list_relays()

      cond do
        connected_relays == [] ->
          {:ok, signed, :no_relays}

        true ->
          case NostrEx.send_event(signed) do
            {:error, reason} -> {:ok, signed, {:error, reason}}
            _ ->
             EventHandler.process_event(signed)
             {:ok, signed}
          end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def format_attrs(%{"id" => event_id, "content" => _content} = attrs) do
    attrs
    |> Map.put("event_id", event_id)
    |> Map.update!("content", fn c -> if(c == "", do: nil, else: c) end)
  end

  def max_created_at(opts \\ []) do
    kinds = Keyword.get(opts, :kinds, [])
    authors = Keyword.get(opts, :authors, [])

    query =
      from(e in Event, select: max(e.created_at))
      |> maybe_filter_kinds(kinds)
      |> maybe_filter_authors(authors)

    Mist.Repo.one(query)
  end

  def since_for_filter(opts \\ []) do
    case max_created_at(opts) do
      nil -> System.os_time(:second) - @default_since_window
      ts -> ts
    end
  end

  def default_limit, do: @default_limit

  @doc """
  Returns the 50 most recent kind-1 notes, with author profiles batch-loaded.
  """
  def list_recent do
    from(e in Event,
      where: e.kind == 1,
      order_by: [desc: e.created_at],
      limit: 50
    )
    |> Mist.Repo.all()
    |> Mist.Repo.preload(:tags)
    |> assemble_notes()
  end

  @doc """
  Returns the 50 most recent kind-1 notes authored by the given pubkeys.
  Returns [] immediately when pubkeys is empty.
  """
  def list_recent_by_pubkeys([]), do: []
  def list_recent_by_pubkeys(pubkeys) do
    from(e in Event,
      where: e.kind == 1 and e.pubkey in ^pubkeys,
      order_by: [desc: e.created_at],
      limit: 50
    )
    |> Mist.Repo.all()
    |> Mist.Repo.preload(:tags)
    |> assemble_notes()
  end

  @doc """
  Returns the 50 most recent kind-1 notes tagged with the given hashtag.
  Returns [] immediately when tag is blank.
  """
  def list_recent_by_hashtag(""), do: []
  def list_recent_by_hashtag(tag) do
    clean = tag |> String.trim() |> String.downcase() |> String.replace(~r/^#/, "")

    id_subquery =
      from(e in Event,
        join: t in assoc(e, :tags),
        where: e.kind == 1 and t.key == "t" and t.value == ^clean,
        group_by: [e.id, e.created_at],
        order_by: [desc: e.created_at],
        limit: 50,
        select: e.id
      )

    from(e in Event,
      join: t in assoc(e, :tags),
      where: e.id in subquery(id_subquery),
      order_by: [desc: e.created_at],
      preload: [tags: t]
    )
    |> Mist.Repo.all()
    |> Enum.uniq_by(& &1.id)
    |> assemble_notes()
  end

  defp assemble_notes(events) do
    pubkeys = Enum.map(events, & &1.pubkey) |> Enum.uniq()

    profile_map =
      from(p in Profile, where: p.pubkey in ^pubkeys)
      |> Mist.Repo.all()
      |> Map.new(fn p -> {p.pubkey, p} end)

    Enum.map(events, fn event ->
      profile = Map.get(profile_map, event.pubkey)

      tags =
        Enum.map(event.tags, fn t ->
          %{type: t.key, data: t.value, info: t.rest || []}
        end)

      %{
        id: event.event_id,
        pubkey: event.pubkey,
        content: event.content,
        created_at: event.created_at,
        sig: event.sig,
        kind: event.kind,
        tags: tags,
        author: if(profile, do: profile.name, else: nil),
        bot: if(profile, do: profile.bot, else: false),
        reaction_count: 0,
        boost_count: 0,
        zap_amount: 0
      }
    end)
  end

  defp maybe_filter_kinds(query, []), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  defp maybe_filter_authors(query, []), do: query
  defp maybe_filter_authors(query, authors), do: where(query, [e], e.pubkey in ^authors)
end
