defmodule Mist.Notes do
  import Ecto.Query

  alias Mist.Nostr.Event

  @default_since_window Application.compile_env(:mist, :subscription_since_window, 86_400)
  @default_limit Application.compile_env(:mist, :subscription_limit, 500)

  def publish(content) when is_binary(content) do
    alias Mist.Nostr.{Signer, EventHandler}

    with {:ok, pubkey} <- Signer.get_public_key(),
         {:ok, unsigned} <- NostrEx.create_event(1, content: content, pubkey: pubkey),
         {:ok, signed} <- Signer.sign_event(unsigned) do
      EventHandler.process_event(signed)

      profile = Mist.Profile.get_by_pubkey(signed.pubkey)

      event_map = %{
        id: signed.id,
        pubkey: signed.pubkey,
        content: signed.content,
        created_at: signed.created_at,
        sig: signed.sig,
        kind: signed.kind,
        tags: [],
        author: if(profile, do: profile.name, else: nil),
        bot: if(profile, do: profile.bot, else: false),
        reaction_count: 0,
        boost_count: 0,
        zap_amount: 0
      }

      connected_relays = NostrEx.list_relays()

      cond do
        connected_relays == [] ->
          {:ok, event_map, :no_relays}

        true ->
          case NostrEx.send_event(signed) do
            {:error, reason} -> {:ok, event_map, {:relay_error, reason}}
            _ -> {:ok, event_map}
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

  defp maybe_filter_kinds(query, []), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  defp maybe_filter_authors(query, []), do: query
  defp maybe_filter_authors(query, authors), do: where(query, [e], e.pubkey in ^authors)
end
