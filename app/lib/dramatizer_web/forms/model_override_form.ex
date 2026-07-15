defmodule DramatizerWeb.Forms.ModelOverrideForm do
  @moduledoc "Casts task-specific project model controls without exposing provider JSON."

  @image_tasks ~w(reference_image shot_keyframe image_edit)a
  @qualities ~w(low medium high)
  @reasoning_efforts ~w(minimal low medium high)

  def cast(task_type, params) when is_atom(task_type) and is_map(params) do
    if task_type in @image_tasks do
      cast_image(params)
    else
      cast_text(params)
    end
  end

  defp cast_image(params) do
    quality = blank_to_nil(params["quality"])
    size = blank_to_nil(params["size"])
    count = blank_to_nil(params["candidate_count"])

    errors =
      []
      |> maybe_error(:quality, quality && quality not in @qualities, "请选择 low、medium 或 high")
      |> maybe_error(:size, size && !Regex.match?(~r/^\d+x\d+$/, size), "尺寸必须形如 768x1360")
      |> validate_candidate_count(count)

    if errors == [] do
      with {:ok, parsed_count} <- parse_optional_positive_integer(count) do
        provider_params =
          %{}
          |> maybe_put("quality", quality)
          |> maybe_put("size", size)
          |> maybe_put("candidate_count", parsed_count)

        {:ok, %{model: blank_to_nil(params["model"]), params: provider_params}}
      end
    else
      {:error, errors}
    end
  end

  defp cast_text(params) do
    effort = blank_to_nil(params["reasoning_effort"])

    errors =
      maybe_error([], :reasoning_effort, effort && effort not in @reasoning_efforts, "请选择有效推理强度")

    if errors == [] do
      provider_params = if effort, do: %{"reasoning" => %{"effort" => effort}}, else: %{}
      {:ok, %{model: blank_to_nil(params["model"]), params: provider_params}}
    else
      {:error, errors}
    end
  end

  defp validate_candidate_count(errors, nil), do: errors

  defp validate_candidate_count(errors, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> errors
      _ -> errors ++ [candidate_count: "候选数必须是正整数"]
    end
  end

  defp parse_optional_positive_integer(nil), do: {:ok, nil}

  defp parse_optional_positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_candidate_count}
    end
  end

  defp maybe_error(errors, _field, nil, _message), do: errors
  defp maybe_error(errors, _field, false, _message), do: errors
  defp maybe_error(errors, field, true, message), do: errors ++ [{field, message}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
