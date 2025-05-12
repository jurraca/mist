defmodule Mist.Relay.Status do

  use Ecto.Schema

  embedded_schema do
    field :relay_name, :string
    field :connected?, :boolean
    field :url, :string
    embeds_one :relay_info, Mist.Relay.Info
  end

end
