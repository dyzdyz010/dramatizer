defmodule Dramatizer.Directing do
  @moduledoc "Editable directing proposals and ShotPlan Draft boundaries."

  import Ecto.Query

  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.{Draft, Revision}

  def proposal_authority(
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        %Revision{project_id: project_id, kind: :visual_design} = visual_design,
        %Revision{project_id: project_id, kind: :reference_set} = reference_set
      ) do
    {:ok,
     %{
       "narrative_revision_id" => narrative.id,
       "visual_design_revision_id" => visual_design.id,
       "reference_set_revision_id" => reference_set.id,
       "narrative" => narrative.payload,
       "visual_design" => visual_design.payload,
       "reference_set" => reference_set.payload,
       "production_profile" => narrative.profile_snapshot
     }}
  end

  def proposal_authority(%Revision{}, %Revision{}, %Revision{}),
    do: {:error, :confirmed_production_revisions_required}

  def create_proposal_draft(
        %Project{id: project_id} = project,
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        %Revision{project_id: project_id, kind: :visual_design} = visual_design,
        %Revision{project_id: project_id, kind: :reference_set} = reference_set,
        proposal_output
      )
      when is_map(proposal_output) do
    existing =
      Repo.all(
        from draft in Draft,
          where:
            draft.project_id == ^project_id and draft.kind == :shot_plan and
              draft.status == :editing,
          order_by: [desc: draft.inserted_at]
      )
      |> Enum.find(&(&1.provenance["reference_set_revision_id"] == reference_set.id))

    if existing do
      {:ok, existing}
    else
      payload =
        proposal_output
        |> Map.put("schema_version", "shot-plan-draft-v2")
        |> Map.put("narrative_revision_id", narrative.id)
        |> Map.put("visual_design_revision_id", visual_design.id)
        |> Map.put("reference_set_revision_id", reference_set.id)

      Revisions.create_draft(
        project,
        :shot_plan,
        payload,
        %{
          "origin" => "directing_proposal",
          "narrative_revision_id" => narrative.id,
          "visual_design_revision_id" => visual_design.id,
          "reference_set_revision_id" => reference_set.id
        }
      )
    end
  end

  def create_proposal_draft(%Project{}, %Revision{}, %Revision{}, %Revision{}, _output),
    do: {:error, :confirmed_production_revisions_required}

  def create_shot_plan_draft(
        %Project{id: project_id} = project,
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        %Revision{project_id: project_id, kind: :visual_design} = visual_design,
        proposal
      )
      when is_map(proposal) do
    payload =
      proposal
      |> Map.put_new("schema_version", "shot-plan-draft-v2")
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
