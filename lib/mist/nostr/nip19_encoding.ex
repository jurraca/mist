defmodule Mist.Nostr.NIP19 do
  @moduledoc """
    parse NIP-19 Bech32 encoded entities.
  """

  def parse(binary) when is_binary(binary) do
    case Bechamel.decode(binary) do
      {:ok, "nprofile", data} -> parse_nprofile(data)
      {:ok, "nevent", data} -> parse_nevent(data)
      {:ok, "note", data} -> parse_note(data)
      {:ok, "nrelay", data} -> parse_nrelay(data)
      {:ok, "naddr", data} -> parse_naddr(data)
      _ -> {:error, "invalid NIP-19 entity"}
    end
  end

  def parse_nprofile(<<0, 32, pubkey::256, rest::binary>>) do
    pubkey = bin_to_hex(pubkey)
    acc = %{type: :nprofile, pubkey: pubkey}
    parse_field(rest, acc)
  end

  def parse_nevent(<<0, 32, id::256, rest::binary>>) do
    event_id = bin_to_hex(id)
    acc = %{type: :nevent, id: event_id}
    parse_field(rest, acc)
  end

  def parse_note(id) do
    {:ok, %{type: :note, id: Base.encode16(id, case: :lower)}}
  end

  def parse_nrelay(<<0, len::8, rest::binary>>) do
    {relay_url, rest} = slice_bit_length(rest, len)
    acc = %{type: :nrelay, relay: relay_url}
    parse_field(rest, acc)
  end

  def parse_naddr(<<0, len::8, rest::binary>>) do
    {addr, rest} = slice_bit_length(rest, len)
    acc = %{type: :naddr, event: addr}
    parse_field(rest, acc)
  end

  def parse_field(nil, acc), do: {:ok, acc}
  def parse_field(<<>>, acc), do: {:ok, acc}

  def parse_field(<<1, len::8, rest::binary>>, acc) do
    {relay_url, rest} = slice_bit_length(rest, len)
    acc = case :relays in Map.keys(acc) do
        false -> Map.put(acc, :relays, [relay_url])
        true -> Map.update(acc, :relays, [], fn v -> v ++ [relay_url] end)
        end
    parse_field(rest, acc)
  end

  def parse_field(<<2, 32, pk::256, rest::binary>>, acc) do
    pubkey = bin_to_hex(pk)
    acc = Map.put(acc, :pubkey, pubkey)
    parse_field(rest, acc)
  end

  def parse_field(<<3, 32, kind::256, rest::binary>>, acc) do
    kind = bin_to_hex(kind)
    acc = Map.put(acc, :kind, kind)
    parse_field(rest, acc)
  end

  def parse_field(_, acc), do: parse_field(nil, acc)

  defp slice_bit_length(binary, length) do
    <<slice::binary-size(length), rest::binary>> = binary
    {slice, rest}
  end

  defp bin_to_hex(bin), do: bin |> :binary.encode_unsigned() |> Base.encode16(case: :lower)
end
