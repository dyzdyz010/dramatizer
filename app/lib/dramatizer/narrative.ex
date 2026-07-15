defmodule Dramatizer.Narrative do
  @moduledoc "Materializes one selected analysis candidate into an editable Narrative Draft."

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.Projects.Project
  alias Dramatizer.Revisions

  def materialize_episode(
        %Project{id: project_id} = project,
        %AnalysisSnapshot{project_id: project_id} = snapshot,
        candidate_id
      ) do
    items = all_items(snapshot.node_results)
    by_id = Map.new(items, &{&1["id"], &1})

    case Map.get(by_id, candidate_id) do
      %{"kind" => "episode"} = episode ->
        dependency_ids = dependency_closure(episode["references"], by_id, MapSet.new())

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
        dependency_closure(rest ++ item["references"], by_id, MapSet.put(seen, id))

      true ->
        dependency_closure(rest, by_id, seen)
    end
  end
end
