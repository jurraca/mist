defmodule Mist.Nostr.RelayMetadata do
  alias Nostr.{Event, Tag}

  @kind 10002

  @doc """
  Takes a list of relays or tuples of the form {relay_url, "read" | "write"}.
  """
  def create(relay_opts) do
    tags =
      relay_opts
      |> Enum.map(fn
        {relay, rw} -> Tag.create(:r, relay, rw)
        relay when is_binary(relay) -> Tag.create(:r, relay)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Event.create(@kind, tags: tags, content: "")
  end
end
