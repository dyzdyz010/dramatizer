defmodule Dramatizer.Analysis.DAG do
  @moduledoc "Persisted six-node whole-document analysis graph."

  import Ecto.Query

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Sources
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  @definition [
    {"people_relations", []},
    {"places_props_world", []},
    {"events_timeline", []},
    {"entity_merge", ~w(people_relations places_props_world events_timeline)},
    {"episode_candidates", ["entity_merge"]},
    {"conflict_check", ["episode_candidates"]}
  ]

  def definition, do: @definition

  def start(%Project{} = project, source_revision_ids) do
    with {:ok, input} <- Sources.analysis_input(project, source_revision_ids),
         {:ok, run} <-
           Workflow.create_run(
             project,
             "whole_novel_analysis_v1",
             %{
               "source_revision_ids" => source_revision_ids,
               "source_content_hash" => input.content_hash,
               "strategy" => "whole_document"
             },
             "whole-novel:#{input.content_hash}"
           ) do
      nodes =
        Enum.map(@definition, fn {node_key, parents} ->
          {:ok, node} =
            Workflow.add_node(
              run,
              node_key,
              %{
                "task_type" => node_key,
                "whole_document" => input.text,
                "source_revision_ids" => source_revision_ids,
                "source_content_hash" => input.content_hash,
                "strategy" => "whole_document"
              },
              parents
            )

          node
        end)

      {:ok, run, nodes}
    end
  end

  def finalize(%WorkflowRun{} = run) do
    nodes =
      Repo.all(
        from node in NodeRun,
          where: node.workflow_run_id == ^run.id,
          order_by: [asc: node.inserted_at]
      )

    if length(nodes) == length(@definition) and Enum.all?(nodes, &(&1.status == :succeeded)) do
      node_results = Map.new(nodes, &{&1.node_key, &1.result})

      task_snapshot_ids =
        nodes
        |> Enum.flat_map(fn node -> Map.get(node.result, "provider_request_snapshot_ids", []) end)
        |> Enum.uniq()

      attrs = %{
        project_id: run.project_id,
        workflow_run_id: run.id,
        source_revision_ids: run.input_snapshot["source_revision_ids"],
        task_snapshot_ids: task_snapshot_ids,
        node_results: node_results,
        content_hash:
          CanonicalJSON.hash(%{
            "source_revision_ids" => run.input_snapshot["source_revision_ids"],
            "task_snapshot_ids" => task_snapshot_ids,
            "node_results" => node_results
          })
      }

      %AnalysisSnapshot{}
      |> AnalysisSnapshot.create_changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:workflow_run_id])

      {:ok, Repo.get_by!(AnalysisSnapshot, workflow_run_id: run.id)}
    else
      {:error, :analysis_incomplete}
    end
  end
end
