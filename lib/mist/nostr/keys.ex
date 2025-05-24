defmodule Mist.Nostr.Keys do
  @moduledoc """
  Handles private key management
  """

  def get_private_key do
    case Application.get_env(:mist, :private_key) do
      nil ->
        {:error, "NOSTR_PRIVKEY environment variable is not set"}

      key when byte_size(key) != 64 ->
        {:error, "Invalid private key format - must be 32 bytes hex encoded"}

      key ->
        {:ok, key}
    end
  end

  def derive_public_key do
    case get_private_key() do
      {:ok, priv_key} ->
        try do
          case Base.decode16(priv_key, case: :lower) do
            {:ok, priv_key_bytes} ->
              hex_pub_key =
                priv_key_bytes
                |> Secp256k1.pubkey(:compressed)
                |> Base.encode16(case: :lower)

              {:ok, hex_pub_key}

            _ ->
              {:error, "Invalid hex encoding for private key"}
          end
        catch
          err -> {:error, "Failed to derive public key: #{inspect(err)}"}
        end

      {:error, _} = err ->
        err
    end
  end
end
