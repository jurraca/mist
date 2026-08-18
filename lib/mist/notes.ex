defmodule Mist.Notes do
  import Ecto.Query

  alias Mist.Nostr.{Event, Tags}
  alias Mist.Profile.Profile

  @default_since_window Application.compile_env(:mist, :subscription_since_window, 86_400)
  @default_limit Application.compile_env(:mist, :subscription_limit, 500)

  @interaction_kinds [6, 7, 9735]

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
            {:ok, _event_id, []} ->
              EventHandler.process_event(signed)
              {:ok, signed}

            {:ok, _event_id, failures} ->
              EventHandler.process_event(signed)
              {:ok, signed, {:relay_error, failures}}

            {:error, reason} ->
              {:ok, signed, {:error, reason}}

            {:error, _msg, failures} ->
              {:ok, signed, {:error, failures}}
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
  Interaction counts (reactions kind 7, boosts kind 6, zaps kind 9735) for the
  given note ids, computed from the DB. Returns `%{note_id => counts_map}`;
  notes without interactions are absent from the map.

  TODO: zap amounts are currently counted as a flat 1000 sats per zap receipt;
  real amounts require bolt11 parsing.
  """
  def counts_for(note_ids) when is_list(note_ids) do
    if note_ids == [] do
      %{}
    else
      from(t in Tags,
        join: e in Event,
        on: t.event_id == e.id,
        where: t.key == "e" and t.value in ^note_ids and e.kind in ^@interaction_kinds,
        group_by: [t.value, e.kind],
        select: {t.value, e.kind, count(e.id)}
      )
      |> Mist.Repo.all()
      |> Enum.reduce(%{}, fn {note_id, kind, count}, acc ->
        counts = Map.get(acc, note_id, zero_counts())
        Map.put(acc, note_id, add_count(counts, kind, count))
      end)
    end
  end

  def zero_counts, do: %{reaction_count: 0, boost_count: 0, zap_amount: 0}

  defp add_count(counts, 7, n), do: %{counts | reaction_count: counts.reaction_count + n}
  defp add_count(counts, 6, n), do: %{counts | boost_count: counts.boost_count + n}
  # TODO: parse the bolt11 tag for real zap amounts
  defp add_count(counts, 9735, n), do: %{counts | zap_amount: counts.zap_amount + n * 1000}

  @doc """
  The single canonical note shape consumed by the UI (list stream, graph,
  live broadcasts). Accepts a stored `%Mist.Nostr.Event{}` (tags preloaded) or
  a freshly received `%NostrCore.Event{}`. Does its own profile/count lookups —
  use `assemble_notes/1` for batches.
  """
  def note_view(%NostrCore.Event{} = event) do
    profile = Mist.Repo.get_by(Profile, pubkey: event.pubkey)
    counts = counts_for([event.id]) |> Map.get(event.id, zero_counts())
    build_note_view(event, profile, counts)
  end

  def note_view(%Event{} = event) do
    event = Mist.Repo.preload(event, :tags)
    profile = Mist.Repo.get_by(Profile, pubkey: event.pubkey)
    counts = counts_for([event.event_id]) |> Map.get(event.event_id, zero_counts())
    build_note_view(event, profile, counts)
  end

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

    counts_map = counts_for(Enum.map(events, & &1.event_id))

    Enum.map(events, fn event ->
      build_note_view(
        event,
        Map.get(profile_map, event.pubkey),
        Map.get(counts_map, event.event_id, zero_counts())
      )
    end)
  end

  defp build_note_view(event, profile, counts) do
    %{
      id: event_id(event),
      pubkey: event.pubkey,
      content: event.content || "",
      created_at: unix_created_at(event),
      sig: event.sig,
      kind: event.kind,
      tags: normalize_tags(event),
      author: if(profile, do: profile.name, else: nil),
      bot: if(profile, do: profile.bot, else: false),
      reaction_count: counts.reaction_count,
      boost_count: counts.boost_count,
      zap_amount: counts.zap_amount
    }
  end

  defp event_id(%NostrCore.Event{id: id}), do: id
  defp event_id(%Event{event_id: id}), do: id

  defp unix_created_at(%NostrCore.Event{created_at: %DateTime{} = dt}), do: DateTime.to_unix(dt)
  defp unix_created_at(%NostrCore.Event{created_at: nil}), do: nil
  defp unix_created_at(%Event{created_at: ts}), do: ts

  defp normalize_tags(%NostrCore.Event{tags: tags}) do
    Enum.map(tags, fn t -> %{type: t.type, data: t.data, info: t.info || []} end)
  end

  defp normalize_tags(%Event{tags: tags}) do
    Enum.map(tags, fn t -> %{type: t.key, data: t.value, info: t.rest || []} end)
  end

  defp maybe_filter_kinds(query, []), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  defp maybe_filter_authors(query, []), do: query
  defp maybe_filter_authors(query, authors), do: where(query, [e], e.pubkey in ^authors)
end
