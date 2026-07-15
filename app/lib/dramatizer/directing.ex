defmodule Dramatizer.Directing do
  @moduledoc "Editable directing proposals and ShotPlan Draft boundaries."

  alias Dramatizer.Projects.Project
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.Revision

  def create_shot_plan_draft(
        %Project{id: project_id} = project,
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        %Revision{project_id: project_id, kind: :visual_design} = visual_design,
        proposal
      )
      when is_map(proposal) do
    payload =
      proposal
      |> Map.put("narrative_revision_id", narrative.id)
      |> Map.put("visual_design_revision_id", visual_design.id)
      |> Map.put_new("sound_strategy", "silent_placeholder")
      |> Map.put_new("continuity", %{})

    Revisions.create_draft(
      project,
      :shot_plan,
      payload,
      %{
        "origin" => "directing_proposal",
        "narrative_revision_id" => narrative.id,
        "visual_design_revision_id" => visual_design.id
      }
    )
  end

  def create_shot_plan_draft(%Project{}, _narrative, _visual_design, _proposal),
    do: {:error, :confirmed_production_revisions_required}
end
