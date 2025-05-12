defmodule Mist.Nostr.RelayStatus do

  use Ecto.Schema

  alias Mist.Nostr.Relay

  embedded_schema do
    field :relay_name, :string
    field :connected?, :boolean
    field :url, :string
    embeds_one :relay_info, Relay
  end

end
