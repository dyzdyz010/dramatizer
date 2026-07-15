defmodule Dramatizer.CanonicalJSON do
  @moduledoc "Deterministic JSON encoding and SHA-256 hashing for immutable snapshots."

  def encode(value), do: encode_value(value)

  def hash(value) do
    value
    |> encode()
    |> hash_bytes()
  end

  def hash_bytes(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> encode_value(item) end)

    "{" <> entries <> "}"
  end

  defp encode_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"
  end

  defp encode_value(value) when is_atom(value) and value not in [true, false, nil] do
    Jason.encode!(Atom.to_string(value))
  end

  defp encode_value(value), do: Jason.encode!(value)
end
