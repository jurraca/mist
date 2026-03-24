defmodule Mist.Relay.Status do
  @enforce_keys [:id, :url, :relay_name, :connected?]
  defstruct [:id, :url, :relay_name, :connected?, relay_info: nil]
end
