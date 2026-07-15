defmodule Dramatizer.Generation.ConfigResolver do
  @moduledoc "Resolves system, Project, and one-shot task provider configuration."

  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project

  def resolve(task_type, %Project{} = project, task_override \\ %{}) do
    system =
      :dramatizer
      |> Application.fetch_env!(:model_defaults)
      |> Map.fetch!(task_type)

    project_values =
      case Projects.model_override(project, task_type) do
        nil -> %{}
        value -> Map.take(value, [:adapter, :credential_ref, :model, :params])
      end

    system
    |> merge_config(project_values)
    |> merge_config(Map.new(task_override))
    |> Map.put(:task_type, task_type)
  end

  defp merge_config(base, overrides) do
    non_nil = overrides |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    merged_params = deep_merge(Map.get(base, :params, %{}), Map.get(non_nil, :params, %{}))

    base
    |> Map.merge(Map.delete(non_nil, :params))
    |> Map.put(:params, merged_params)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
