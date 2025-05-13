defmodule Mist.Utils do

  def collect(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(oks, fn {:ok, v} -> v end)}
      errors -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end
end
