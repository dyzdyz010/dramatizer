defmodule Dramatizer.Analysis.Schemas do
  @moduledoc "Versioned strict structured-output schemas for whole-novel analysis tasks."

  @task_types ~w(people_relations places_props_world events_timeline entity_merge episode_candidates conflict_check)a
  @version "analysis-schema-v2"

  def version, do: @version

  def fetch!(task_type) when task_type in @task_types do
    :dramatizer
    |> Application.app_dir("priv/analysis_schemas/analysis_items.json")
    |> File.read!()
    |> Jason.decode!()
  end

  def name(task_type) when task_type in @task_types, do: "dramatizer_#{task_type}_v1"
end
