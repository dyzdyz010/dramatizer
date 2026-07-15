defmodule Dramatizer.Analysis.Validator do
  @moduledoc "Strict JSON Schema followed by deterministic cross-field and source validation."

  alias Dramatizer.Analysis.Schemas

  def validate(task_type, value, opts \\ []) do
    with {:ok, decoded} <- decode(value) do
      schema_errors = validate_schema(decoded, Schemas.fetch!(task_type), "/")

      if schema_errors == [] do
        case domain_errors(decoded, opts) do
          [] -> {:ok, decoded}
          errors -> {:error, errors}
        end
      else
        {:error, schema_errors}
      end
    end
  end

  defp decode(value) when is_map(value), do: {:ok, value}

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, [%{code: :invalid_json, path: "/"}]}
    end
  end

  defp decode(_value), do: {:error, [%{code: :invalid_json, path: "/"}]}

  defp validate_schema(value, schema, path) do
    type_errors = type_errors(value, schema["type"], path)

    if type_errors == [] do
      enum_errors(value, schema, path) ++
        scalar_errors(value, schema, path) ++
        object_errors(value, schema, path) ++
        array_errors(value, schema, path)
    else
      type_errors
    end
  end

  defp type_errors(_value, nil, _path), do: []
  defp type_errors(value, "object", path) when not is_map(value), do: [error(:type, path)]
  defp type_errors(value, "array", path) when not is_list(value), do: [error(:type, path)]
  defp type_errors(value, "string", path) when not is_binary(value), do: [error(:type, path)]
  defp type_errors(value, "integer", path) when not is_integer(value), do: [error(:type, path)]
  defp type_errors(_value, _type, _path), do: []

  defp enum_errors(value, %{"enum" => allowed}, path) do
    if value in allowed, do: [], else: [error(:enum, path)]
  end

  defp enum_errors(_value, _schema, _path), do: []

  defp scalar_errors(value, schema, path) when is_binary(value) do
    if String.length(value) < Map.get(schema, "minLength", 0),
      do: [error(:min_length, path)],
      else: []
  end

  defp scalar_errors(value, schema, path) when is_integer(value) do
    case schema["minimum"] do
      minimum when is_integer(minimum) and value < minimum -> [error(:minimum, path)]
      _ -> []
    end
  end

  defp scalar_errors(_value, _schema, _path), do: []

  defp object_errors(value, schema, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    required_errors =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&Map.has_key?(value, &1))
      |> Enum.map(&error(:required, child_path(path, &1)))

    additional_errors =
      if schema["additionalProperties"] == false do
        value
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(properties, &1))
        |> Enum.sort()
        |> Enum.map(&error(:additional_property, child_path(path, &1)))
      else
        []
      end

    property_errors =
      properties
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, child_schema} ->
        if Map.has_key?(value, key) do
          validate_schema(value[key], child_schema, child_path(path, key))
        else
          []
        end
      end)

    additional_errors ++ required_errors ++ property_errors
  end

  defp object_errors(_value, _schema, _path), do: []

  defp array_errors(value, schema, path) when is_list(value) do
    minimum_errors =
      if length(value) < Map.get(schema, "minItems", 0),
        do: [error(:min_items, path)],
        else: []

    item_errors =
      case schema["items"] do
        child_schema when is_map(child_schema) ->
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, index} ->
            validate_schema(item, child_schema, child_path(path, index))
          end)

        _ ->
          []
      end

    minimum_errors ++ item_errors
  end

  defp array_errors(_value, _schema, _path), do: []

  defp domain_errors(%{"items" => items}, opts) do
    known_ids = items |> Enum.map(& &1["id"]) |> MapSet.new()
    allowed_sources = opts |> Keyword.get(:source_revision_ids, []) |> MapSet.new()

    duplicate_errors(items) ++
      Enum.flat_map(Enum.with_index(items), fn {item, index} ->
        item_path = "/items/#{index}"

        locator_errors(item, item_path, allowed_sources) ++
          reference_errors(item, item_path, known_ids)
      end)
  end

  defp duplicate_errors(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {item, index}, {seen, errors} ->
      id = item["id"]

      if MapSet.member?(seen, id) do
        {seen, errors ++ [error(:duplicate_id, "/items/#{index}/id")]}
      else
        {MapSet.put(seen, id), errors}
      end
    end)
    |> elem(1)
  end

  defp locator_errors(item, item_path, allowed_sources) do
    locators = item["locators"]

    required =
      if item["source_semantics"] in ["source_grounded", "inferred"] and locators == [],
        do: [error(:locator_required, item_path <> "/locators")],
        else: []

    ranges =
      locators
      |> Enum.with_index()
      |> Enum.flat_map(fn {locator, index} ->
        path = item_path <> "/locators/#{index}"

        range_error =
          if locator["end_offset"] < locator["start_offset"],
            do: [error(:invalid_range, path)],
            else: []

        source_error =
          if MapSet.size(allowed_sources) > 0 and
               not MapSet.member?(allowed_sources, locator["source_revision_id"]),
             do: [error(:unknown_source_revision, path <> "/source_revision_id")],
             else: []

        range_error ++ source_error
      end)

    required ++ ranges
  end

  defp reference_errors(item, item_path, known_ids) do
    item["references"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {reference, index} ->
      if MapSet.member?(known_ids, reference),
        do: [],
        else: [error(:dangling_reference, item_path <> "/references/#{index}")]
    end)
  end

  defp child_path("/", child), do: "/#{child}"
  defp child_path(path, child), do: "#{path}/#{child}"
  defp error(code, path), do: %{code: code, path: path}
end
