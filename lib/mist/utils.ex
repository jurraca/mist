defmodule Mist.Utils do

  def collect(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(oks, fn {:ok, v} -> v end)}
      errors -> {:error, errors |> Enum.reject(&is_nil/1) |> Enum.map(fn {:error, e} -> e end)}
    end
  end
end
