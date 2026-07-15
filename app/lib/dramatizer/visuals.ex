defmodule Dramatizer.Visuals do
  @moduledoc "VisualDesign variants, reference requirements, and primary reference slots."

  import Ecto.Query

  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.{Draft, Revision}

  @slots %{
    "character" => ~w(face_closeup three_quarter_full expression_features),
    "location" => ~w(spatial_wide primary_direction key_lighting),
    "prop" => ~w(overall key_detail_state)
  }

  def proposal_authority(%Revision{kind: :narrative} = narrative) do
    {:ok,
     %{
       "narrative_revision_id" => narrative.id,
       "narrative" => narrative.payload,
       "production_profile" => narrative.profile_snapshot
     }}
  end

  def proposal_authority(%Revision{}), do: {:error, :confirmed_narrative_required}

  def create_proposal_draft(
        %Project{id: project_id} = project,
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        proposal_output
      )
      when is_map(proposal_output) do
    existing =
      Repo.all(
        from draft in Draft,
          where:
            draft.project_id == ^project_id and draft.kind == :visual_design and
              draft.status == :editing,
          order_by: [desc: draft.inserted_at]
      )
      |> Enum.find(&(&1.provenance["narrative_revision_id"] == narrative.id))

    if existing do
      {:ok, existing}
    else
      with {:ok, normalized} <- normalize_objects(proposal_output["objects"] || []) do
        payload =
          proposal_output
          |> Map.put("schema_version", "visual-design-draft-v2")
          |> Map.put("narrative_revision_id", narrative.id)
          |> Map.put("objects", normalized)
          |> Map.put_new("slot_template_version", "visual-slots-v1")

        Revisions.create_draft(
          project,
          :visual_design,
          payload,
          %{
            "origin" => "visual_design_proposal",
            "narrative_revision_id" => narrative.id
          }
        )
      end
    end
  end

  def create_proposal_draft(%Project{}, %Revision{}, _proposal_output),
    do: {:error, :confirmed_narrative_required}

  def create_design_draft(%Project{} = project, narrative_revision, objects)
      when is_list(objects) do
    with :ok <- validate_narrative(project, narrative_revision),
         {:ok, normalized} <- normalize_objects(objects) do
      Revisions.create_draft(
        project,
        :visual_design,
        %{
          "schema_version" => "visual-design-draft-v2",
          "narrative_revision_id" => narrative_revision && narrative_revision.id,
          "objects" => normalized,
          "slot_template_version" => "visual-slots-v1"
        },
        %{
          "origin" => "visual_design_proposal",
          "narrative_revision_id" => narrative_revision && narrative_revision.id
        }
      )
    end
  end

  def create_reference_set_draft(%Project{}, %Draft{id: id}, _assignments),
    do: {:error, {:unconfirmed_visual_design, id}}

  def create_reference_set_draft(
        %Project{id: project_id} = project,
        %Revision{project_id: project_id, kind: :visual_design} = visual_revision,
        assignments
      )
      when is_map(assignments) do
    required = required_slot_keys(visual_revision.payload["objects"])

    missing =
      Enum.reject(required, fn key ->
        case Map.get(assignments, key) do
          asset_id when is_binary(asset_id) ->
            not is_nil(Repo.get_by(AssetVersion, id: asset_id, project_id: project_id))

          _ ->
            false
        end
      end)

    if missing == [] do
      primary_assets = Map.take(assignments, required)

      Revisions.create_draft(
        project,
        :reference_set,
        %{
          "visual_design_revision_id" => visual_revision.id,
          "required_slots" => required,
          "primary_assets" => primary_assets,
          "slot_template_version" => "visual-slots-v1"
        },
        %{
          "origin" => "reference_selection",
          "visual_design_revision_id" => visual_revision.id
        }
      )
    else
      {:error, {:missing_primary_assets, missing}}
    end
  end

  def create_reference_set_draft(%Project{}, %Revision{}, _assignments),
    do: {:error, :visual_design_project_or_kind_mismatch}

  def slot_template(type), do: Map.fetch(@slots, type)

  defp validate_narrative(_project, nil), do: :ok

  defp validate_narrative(%Project{id: id}, %Revision{project_id: id, kind: :narrative}),
    do: :ok

  defp validate_narrative(_project, _revision), do: {:error, :confirmed_narrative_required}

  defp normalize_objects(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, normalized} ->
      type = object["type"]

      case Map.fetch(@slots, type) do
        {:ok, slots} ->
          variants =
            object
            |> Map.get("variants", [%{"id" => "default"}])
            |> Enum.map(&Map.put_new(&1, "required_slots", slots))

          reference_required =
            Map.get(
              object,
              "reference_required",
              Map.get(object, "recurring", false) or Map.get(object, "key", false)
            )

          prepared =
            object
            |> Map.put("reference_required", reference_required)
            |> Map.put("variants", variants)

          {:cont, {:ok, normalized ++ [prepared]}}

        :error ->
          {:halt, {:error, {:unsupported_visual_type, type}}}
      end
    end)
  end

  defp required_slot_keys(objects) do
    for object <- objects,
        object["reference_required"],
        variant <- object["variants"],
        slot <- variant["required_slots"] do
      "#{object["id"]}/#{variant["id"]}/#{slot}"
    end
  end
end
