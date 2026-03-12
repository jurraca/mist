defmodule Mist.Nostr.Keys do
  @moduledoc """
  Handles private key management
  """

  @doc """
  Gets the private key, validating its format.
  Returns {:ok, key} or {:error, reason}
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

  def decode_pubkey_input(input) do
    input = String.trim(input)

    cond do
      String.starts_with?(input, "npub") ->
        case ExBech32.decode(input) do
          {:ok, {"npub", data, _}} ->
            {:ok, Base.encode16(data, case: :lower)}

          _ ->
            {:error, "Invalid npub format"}
        end

      Regex.match?(~r/^[0-9a-fA-F]{64}$/, input) ->
        {:ok, String.downcase(input)}

      true ->
        {:error, "Input must be a 64-character hex pubkey or an npub"}
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
                |> Secp256k1.pubkey(:xonly)
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
