defmodule Dramatizer.Projects do
  @moduledoc "Projects and their layered production configuration."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.{ModelOverride, ProductionProfile, Project, PromptAppendix}
  alias Dramatizer.Prompts.Catalog
  alias Dramatizer.Repo
  alias Ecto.Multi

  def create_project(attrs) do
    Multi.new()
    |> Multi.insert(:project, Project.changeset(%Project{}, attrs))
    |> Multi.run(:profile, fn repo, %{project: project} ->
      %ProductionProfile{}
      |> ProductionProfile.changeset(%{project_id: project.id})
      |> repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{project: project}} -> {:ok, project}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def list_projects do
    Repo.all(from project in Project, order_by: [desc: project.updated_at])
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def rename_project(%Project{} = project, name) do
    project
    |> Project.changeset(%{name: name})
    |> Repo.update()
  end

  def archive_project(%Project{} = project) do
    project
    |> Project.changeset(%{status: :archived, archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def update_production_profile(%Project{id: project_id}, attrs) do
    project_id
    |> profile_for_project!()
    |> ProductionProfile.changeset(attrs)
    |> Repo.update()
  end

  def effective_profile(%Project{id: project_id}, episode_override \\ %{}) do
    profile = profile_for_project!(project_id)
    allowed = Map.take(episode_override, ProductionProfile.fields())

    profile
    |> Map.from_struct()
    |> Map.merge(allowed)
    |> Map.take(ProductionProfile.fields())
  end

  def profile_snapshot(project, episode_override \\ %{}) do
    project
    |> effective_profile(episode_override)
    |> ProductionProfile.snapshot()
  end

  def put_model_override(%Project{id: project_id}, task_type, attrs) do
    with :ok <- Catalog.validate_task_type(task_type) do
      values =
        attrs
        |> Map.new()
        |> Map.put(:project_id, project_id)
        |> Map.put(:task_type, Atom.to_string(task_type))

      %ModelOverride{}
      |> ModelOverride.changeset(values)
      |> Repo.insert(
        conflict_target: [:project_id, :task_type],
        on_conflict: {:replace, [:adapter, :credential_ref, :model, :params, :updated_at]},
        returning: true
      )
    end
  end

  def model_override(%Project{id: project_id}, task_type) do
    Repo.get_by(ModelOverride, project_id: project_id, task_type: Atom.to_string(task_type))
  end

  def create_prompt_appendix(%Project{id: project_id}, task_type, body) when is_binary(body) do
    with :ok <- Catalog.validate_task_type(task_type) do
      Repo.transaction(fn ->
        Repo.one!(from project in Project, where: project.id == ^project_id, lock: "FOR UPDATE")

        revision =
          Repo.one(
            from appendix in PromptAppendix,
              where:
                appendix.project_id == ^project_id and
                  appendix.task_type == ^Atom.to_string(task_type),
              select: max(appendix.revision)
          ) || 0

        attrs = %{
          project_id: project_id,
          task_type: Atom.to_string(task_type),
          revision: revision + 1,
          body: body,
          body_hash: CanonicalJSON.hash_bytes(body)
        }

        %PromptAppendix{}
        |> PromptAppendix.changeset(attrs)
        |> Repo.insert!()
      end)
      |> unwrap_transaction()
    end
  end

  def current_prompt_appendix(%Project{id: project_id}, task_type) do
    Repo.one(
      from appendix in PromptAppendix,
        where:
          appendix.project_id == ^project_id and appendix.task_type == ^Atom.to_string(task_type),
        order_by: [desc: appendix.revision],
        limit: 1
    )
  end

  defp profile_for_project!(project_id) do
    Repo.get_by!(ProductionProfile, project_id: project_id)
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}
end
