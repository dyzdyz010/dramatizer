defmodule Dramatizer.Visuals do
  @moduledoc "VisualDesign variants, reference requirements, and primary reference slots."

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

  def create_design_draft(%Project{} = project, narrative_revision, objects)
      when is_list(objects) do
    with :ok <- validate_narrative(project, narrative_revision),
         {:ok, normalized} <- normalize_objects(objects) do
      Revisions.create_draft(
        project,
        :visual_design,
        %{
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
            |> Enum.map(&Map.put(&1, "required_slots", slots))

          reference_required =
            Map.get(object, "recurring", false) or Map.get(object, "key", false)

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
