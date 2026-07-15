defmodule Dramatizer.Revisions do
  @moduledoc "Editable AI/user drafts and immutable confirmed authority revisions."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions.{Draft, Revision}

  def create_draft(%Project{} = project, kind, payload, provenance) do
    %Draft{}
    |> Draft.create_changeset(%{
      project_id: project.id,
      logical_id: Ecto.UUID.generate(),
      kind: kind,
      payload: payload,
      provenance: provenance
    })
    |> Repo.insert()
  end

  def update_draft(%Draft{id: id}, payload_patch) when is_map(payload_patch) do
    draft = Repo.get!(Draft, id)

    if draft.status == :editing do
      merged_payload = Map.merge(draft.payload, payload_patch)

      draft
      |> Draft.edit_changeset(%{payload: merged_payload})
      |> Repo.update()
    else
      {:error, :draft_confirmed}
    end
  end

  def replace_draft_payload(%Draft{id: id, lock_version: expected_lock}, payload)
      when is_map(payload) do
    draft = Repo.get!(Draft, id)

    cond do
      draft.status != :editing ->
        {:error, :draft_confirmed}

      draft.lock_version != expected_lock ->
        {:error, :stale_draft}

      true ->
        draft
        |> Draft.edit_changeset(%{payload: payload})
        |> Repo.update()
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_draft}
  end

  def confirm_draft(draft_id) do
    Repo.transaction(fn ->
      draft = Repo.one!(from item in Draft, where: item.id == ^draft_id, lock: "FOR UPDATE")

      case draft.status do
        :confirmed ->
          Repo.get!(Revision, draft.confirmed_revision_id)

        :editing ->
          project = Projects.get_project!(draft.project_id)

          next_revision =
            (Repo.one(
               from revision in Revision,
                 where: revision.logical_id == ^draft.logical_id,
                 select: max(revision.revision)
             ) || 0) + 1

          content_hash =
            CanonicalJSON.hash(%{
              "kind" => Atom.to_string(draft.kind),
              "payload" => draft.payload
            })

          revision =
            %Revision{}
            |> Revision.create_changeset(%{
              project_id: draft.project_id,
              logical_id: draft.logical_id,
              kind: draft.kind,
              revision: next_revision,
              parent_revision_id: draft.base_revision_id,
              draft_id: draft.id,
              payload: draft.payload,
              provenance: draft.provenance,
              profile_snapshot:
                Projects.profile_snapshot(project, episode_profile_override(draft)),
              content_hash: content_hash
            })
            |> Repo.insert!()

          draft
          |> Draft.confirm_changeset(revision.id)
          |> Repo.update!()

          revision
      end
    end)
    |> case do
      {:ok, revision} -> {:ok, revision}
      {:error, reason} -> {:error, reason}
    end
  end

  def derive_draft(revision_id) do
    revision = Repo.get!(Revision, revision_id)

    %Draft{}
    |> Draft.create_changeset(%{
      project_id: revision.project_id,
      logical_id: revision.logical_id,
      kind: revision.kind,
      base_revision_id: revision.id,
      payload: revision.payload,
      provenance: Map.put(revision.provenance, "derived_from_revision_id", revision.id)
    })
    |> Repo.insert()
  end

  def get_revision!(id), do: Repo.get!(Revision, id)

  defp episode_profile_override(%Draft{kind: :narrative, payload: payload}) do
    override = Map.get(payload, "production_profile_override", %{})

    Map.new(Projects.ProductionProfile.fields(), fn field ->
      {field, Map.get(override, Atom.to_string(field), Map.get(override, field))}
    end)
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp episode_profile_override(%Draft{}), do: %{}
end
