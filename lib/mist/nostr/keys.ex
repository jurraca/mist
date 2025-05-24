defmodule Mist.Nostr.Keys do
  @moduledoc """
  Handles private key management
  """

  def get_private_key do
    Application.get_env(:mist, :private_key) ||
      raise "NOSTR_PRIVATE_KEY environment variable is not set"
  end

  def derive_public_key do
    try do
      get_private_key()
      |> Secp256k1.pubkey(private_key, compress: true)
    end
  end
end