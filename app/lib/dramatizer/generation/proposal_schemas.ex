defmodule Dramatizer.Generation.ProposalSchemas do
  @moduledoc "Versioned strict schemas and deterministic validation for production proposals."

  @tasks ~w(narrative_proposal visual_design_proposal directing_proposal)a

  def fetch!(task_type) when task_type in @tasks do
    :dramatizer
    |> Application.app_dir("priv/proposal_schemas/#{task_type}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  def name(task_type) when task_type in @tasks, do: "dramatizer_#{task_type}_v2"

  def validate(task_type, value) when task_type in @tasks do
    case errors(value, fetch!(task_type), "/") do
      [] -> {:ok, value}
      validation_errors -> {:error, validation_errors}
    end
  end

  defp errors(value, schema, path) do
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

  defp type_errors(value, types, path) when is_list(types) do
    if Enum.any?(types, &matches_type?(value, &1)), do: [], else: [error(:type, path)]
  end

  defp type_errors(value, type, path) do
    if matches_type?(value, type), do: [], else: [error(:type, path)]
  end

  defp matches_type?(value, "object"), do: is_map(value)
  defp matches_type?(value, "array"), do: is_list(value)
  defp matches_type?(value, "string"), do: is_binary(value)
  defp matches_type?(value, "integer"), do: is_integer(value)
  defp matches_type?(value, "number"), do: is_number(value)
  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "null"), do: is_nil(value)
  defp matches_type?(_value, _type), do: false

  defp enum_errors(value, %{"enum" => allowed}, path) do
    if value in allowed, do: [], else: [error(:enum, path)]
  end

  defp enum_errors(_value, _schema, _path), do: []

  defp scalar_errors(value, schema, path) when is_binary(value) do
    minimum = schema["minLength"]
    if minimum && String.length(value) < minimum, do: [error(:min_length, path)], else: []
  end

  defp scalar_errors(value, schema, path) when is_number(value) do
    minimum = schema["minimum"]
    if minimum && value < minimum, do: [error(:minimum, path)], else: []
  end

  defp scalar_errors(_value, _schema, _path), do: []

  defp object_errors(value, schema, path) when is_map(value) do
    properties = schema["properties"] || %{}

    required_errors =
      for key <- schema["required"] || [], not Map.has_key?(value, key) do
        error(:required, join(path, key))
      end

    extra_errors =
      if schema["additionalProperties"] == false do
        for key <- Map.keys(value), not Map.has_key?(properties, key) do
          error(:additional_property, join(path, key))
        end
      else
        []
      end

    nested_errors =
      Enum.flat_map(properties, fn {key, child_schema} ->
        if Map.has_key?(value, key) do
          errors(value[key], child_schema, join(path, key))
        else
          []
        end
      end)

    required_errors ++ extra_errors ++ nested_errors
  end

  defp object_errors(_value, _schema, _path), do: []

  defp array_errors(value, schema, path) when is_list(value) do
    minimum_errors =
      if schema["minItems"] && length(value) < schema["minItems"],
        do: [error(:min_items, path)],
        else: []

    nested_errors =
      case schema["items"] do
        nil ->
          []

        child ->
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, index} -> errors(item, child, join(path, index)) end)
      end

    minimum_errors ++ nested_errors
  end

  defp array_errors(_value, _schema, _path), do: []

  defp join("/", segment), do: "/#{segment}"
  defp join(path, segment), do: "#{path}/#{segment}"
  defp error(code, path), do: %{code: code, path: path}
end
