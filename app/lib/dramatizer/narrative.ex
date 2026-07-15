defmodule Dramatizer.Narrative do
  @moduledoc "Materializes one selected analysis candidate into an editable Narrative Draft."

  import Ecto.Query

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.Analysis.{DAG, Runner}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.Draft
  alias Dramatizer.Sources

  def ensure_analysis(%Project{id: project_id} = project, source_revision_ids)
      when is_list(source_revision_ids) and source_revision_ids != [] do
    expected_ids = Enum.sort(source_revision_ids)

    existing =
      Repo.all(
        from snapshot in AnalysisSnapshot,
          where: snapshot.project_id == ^project_id,
          order_by: [desc: snapshot.inserted_at]
      )
      |> Enum.find(&(Enum.sort(&1.source_revision_ids) == expected_ids))

    if existing do
      {:ok, existing}
    else
      with {:ok, run, _nodes} <- DAG.start(project, source_revision_ids) do
        Runner.run(project, run, Application.fetch_env!(:dramatizer, :provider_mode))
      end
    end
  end

  def ensure_analysis(%Project{}, []), do: {:error, :source_revision_required}

  def proposal_authority(%AnalysisSnapshot{} = snapshot, candidate_id) do
    items = all_items(snapshot.node_results)
    by_id = Map.new(items, &{&1["id"], &1})

    case Map.get(by_id, candidate_id) do
      %{"kind" => "episode"} = candidate ->
        dependency_ids = dependency_closure(candidate["references"] || [], by_id, MapSet.new())
        project = Repo.get!(Project, snapshot.project_id)

        with {:ok, source_input} <- Sources.analysis_input(project, snapshot.source_revision_ids) do
          {:ok,
           %{
             "analysis_snapshot_id" => snapshot.id,
             "source_revision_ids" => snapshot.source_revision_ids,
             "whole_document" => source_input.text,
             "whole_document_hash" => source_input.content_hash,
             "selected_candidate" => candidate,
             "selected_dependencies" =>
               dependency_ids
               |> Enum.map(&Map.fetch!(by_id, &1))
               |> Enum.sort_by(& &1["id"]),
             "analysis_outputs" =>
               Map.new(snapshot.node_results, fn {key, result} ->
                 {key, get_in(result, ["output"]) || %{}}
               end)
           }}
        end

      nil ->
        {:error, :episode_candidate_not_found}

      _other ->
        {:error, :not_an_episode_candidate}
    end
  end

  def create_proposal_draft(
        %Project{id: project_id} = project,
        %AnalysisSnapshot{project_id: project_id} = snapshot,
        candidate_id,
        proposal_output
      )
      when is_map(proposal_output) do
    with {:ok, authority} <- proposal_authority(snapshot, candidate_id) do
      existing =
        Repo.all(
          from draft in Draft,
            where:
              draft.project_id == ^project_id and draft.kind == :narrative and
                draft.status == :editing,
            order_by: [desc: draft.inserted_at]
        )
        |> Enum.find(fn draft ->
          draft.provenance["analysis_snapshot_id"] == snapshot.id and
            draft.provenance["candidate_id"] == candidate_id
        end)

      if existing do
        {:ok, existing}
      else
        payload =
          proposal_output
          |> Map.put("analysis_snapshot_id", snapshot.id)
          |> Map.put("source_revision_ids", snapshot.source_revision_ids)
          |> Map.put("analysis_candidate", authority["selected_candidate"])
          |> Map.put("analysis_dependencies", authority["selected_dependencies"])

        Revisions.create_draft(
          project,
          :narrative,
          payload,
          %{
            "origin" => "narrative_proposal",
            "analysis_snapshot_id" => snapshot.id,
            "candidate_id" => candidate_id,
            "task_snapshot_ids" => snapshot.task_snapshot_ids
          }
        )
      end
    end
  end

  def create_proposal_draft(%Project{}, %AnalysisSnapshot{}, _candidate_id, _output),
    do: {:error, :analysis_project_mismatch}

  def materialize_episode(
        %Project{id: project_id} = project,
        %AnalysisSnapshot{project_id: project_id} = snapshot,
        candidate_id
      ) do
    items = all_items(snapshot.node_results)
    by_id = Map.new(items, &{&1["id"], &1})

    case Map.get(by_id, candidate_id) do
      %{"kind" => "episode"} = episode ->
        dependency_ids = dependency_closure(episode["references"] || [], by_id, MapSet.new())

        dependencies =
          dependency_ids
          |> Enum.map(&Map.fetch!(by_id, &1))
          |> Enum.sort_by(& &1["id"])

        payload =
          episode
          |> Map.get("data", %{})
          |> Map.merge(%{
            "episode" => episode,
            "dependencies" => dependencies,
            "analysis_snapshot_id" => snapshot.id,
            "source_revision_ids" => snapshot.source_revision_ids
          })

        Revisions.create_draft(
          project,
          :narrative,
          payload,
          %{
            "origin" => "analysis_episode_candidate",
            "analysis_snapshot_id" => snapshot.id,
            "candidate_id" => candidate_id,
            "task_snapshot_ids" => snapshot.task_snapshot_ids
          }
        )

      nil ->
        {:error, :episode_candidate_not_found}

      _other ->
        {:error, :not_an_episode_candidate}
    end
  end

  def materialize_episode(%Project{}, %AnalysisSnapshot{}, _candidate_id),
    do: {:error, :analysis_project_mismatch}

  defp all_items(node_results) do
    node_results
    |> Map.values()
    |> Enum.flat_map(fn result -> get_in(result, ["output", "items"]) || [] end)
  end

  defp dependency_closure([], _by_id, seen), do: MapSet.to_list(seen)

  defp dependency_closure([id | rest], by_id, seen) do
    cond do
      MapSet.member?(seen, id) ->
        dependency_closure(rest, by_id, seen)

      item = Map.get(by_id, id) ->
        dependency_closure(rest ++ (item["references"] || []), by_id, MapSet.put(seen, id))

      true ->
        dependency_closure(rest, by_id, seen)
    end
  end
end
