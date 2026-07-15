defmodule Dramatizer.Prompts.Catalog do
  @moduledoc "Versioned, code-owned CorePrompt catalog."

  @version "v1"
  @tasks ~w(people_relations places_props_world events_timeline entity_merge episode_candidates conflict_check narrative_proposal visual_design_proposal directing_proposal image_prompt structured_repair semantic_qc)a

  def version, do: @version
  def task_types, do: @tasks

  def validate_task_type(task_type) when task_type in @tasks, do: :ok
  def validate_task_type(_task_type), do: {:error, :unknown_prompt_task_type}

  def fetch!(task_type) when task_type in @tasks do
    :dramatizer
    |> Application.app_dir("priv/prompts/#{@version}/#{task_type}.md")
    |> File.read!()
    |> String.trim()
  end
end
