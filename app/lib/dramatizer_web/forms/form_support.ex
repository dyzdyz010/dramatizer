defmodule DramatizerWeb.Forms.FormSupport do
  @moduledoc false

  @separators ~r/[\n,，]+/u

  def string_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), string_keys(item)} end)
  end

  def string_keys(value) when is_list(value), do: Enum.map(value, &string_keys/1)
  def string_keys(value), do: value

  def indexed_values(nil), do: []
  def indexed_values(items) when is_list(items), do: Enum.map(items, &string_keys/1)

  def indexed_values(items) when is_map(items) do
    items
    |> Enum.sort_by(fn {key, _value} -> index_key(key) end)
    |> Enum.map(fn {_key, value} -> string_keys(value) end)
  end

  def indexed_values(_items), do: []

  def text_list(nil), do: []

  def text_list(items) when is_list(items) do
    items
    |> Enum.flat_map(&text_list/1)
    |> Enum.uniq()
  end

  def text_list(value) when is_binary(value) do
    value
    |> String.split(@separators)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def text_list(value), do: [to_string(value)]

  def text_list_input(value) when is_list(value), do: Enum.join(value, "\n")
  def text_list_input(value) when is_binary(value), do: value
  def text_list_input(_value), do: ""

  def boolean(value) when value in [true, 1, "1", "true", "on", "yes"], do: true
  def boolean(_value), do: false

  def integer(nil), do: {:ok, nil}
  def integer(""), do: {:ok, nil}
  def integer(value) when is_integer(value), do: {:ok, value}

  def integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  def integer(_value), do: :error

  def decimal(nil), do: {:ok, nil}
  def decimal(""), do: {:ok, nil}
  def decimal(value) when is_number(value), do: {:ok, value * 1.0}

  def decimal(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  def decimal(_value), do: :error

  def value(params, current, key, default \\ "") do
    params = string_keys(params || %{})
    current = string_keys(current || %{})
    Map.get(params, key, Map.get(current, key, default))
  end

  def id(params, current, prefix) do
    case value(params, current, "id", nil) do
      value when is_binary(value) and value != "" -> value
      _other -> "#{prefix}-#{String.slice(Ecto.UUID.generate(), 0, 8)}"
    end
  end

  def merge_preserving(current, owned) when is_map(current) and is_map(owned) do
    Map.merge(string_keys(current), string_keys(owned), fn
      _key, old, new when is_map(old) and is_map(new) -> merge_preserving(old, new)
      _key, _old, new -> new
    end)
  end

  def merge_preserving(_current, owned), do: string_keys(owned)

  def cast_collection(params, current, caster) when is_function(caster, 2) do
    current = indexed_values(current)
    current_by_id = Map.new(current, &{Map.get(&1, "id"), &1})

    params
    |> indexed_values()
    |> Enum.map(fn item -> caster.(item, Map.get(current_by_id, Map.get(item, "id"), %{})) end)
  end

  def unique_ids?(items) do
    ids = Enum.map(items, &Map.get(&1, "id"))
    Enum.all?(ids, &(is_binary(&1) and &1 != "")) and Enum.uniq(ids) == ids
  end

  def conflicts(left, right),
    do: MapSet.intersection(MapSet.new(left), MapSet.new(right)) |> MapSet.to_list()

  def add(payload, collection, item) do
    key = to_string(collection)
    Map.update(string_keys(payload), key, [string_keys(item)], &(&1 ++ [string_keys(item)]))
  end

  def remove(payload, collection, id) do
    key = to_string(collection)
    Map.update(string_keys(payload), key, [], &Enum.reject(&1, fn item -> item["id"] == id end))
  end

  def move(payload, collection, id, direction) when direction in [:up, :down] do
    key = to_string(collection)

    Map.update(string_keys(payload), key, [], fn items ->
      index = Enum.find_index(items, &(&1["id"] == id))
      target = if direction == :up, do: index && index - 1, else: index && index + 1

      if is_integer(index) and is_integer(target) and target >= 0 and target < length(items) do
        selected = Enum.at(items, index)

        items
        |> List.delete_at(index)
        |> List.insert_at(target, selected)
      else
        items
      end
    end)
  end

  def put_error(errors, key, message), do: Map.update(errors, key, [message], &(&1 ++ [message]))

  def required?(value), do: is_binary(value) and String.trim(value) != ""

  defp index_key(key) do
    case Integer.parse(to_string(key)) do
      {integer, ""} -> {0, integer}
      _other -> {1, to_string(key)}
    end
  end
end
