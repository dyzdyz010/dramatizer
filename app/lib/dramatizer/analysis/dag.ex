defmodule Dramatizer.Analysis.DAG do
  @moduledoc "Persisted six-node whole-document analysis graph."

  import Ecto.Query

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.ConfigResolver
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

  def start(%Project{} = project, source_revision_ids, opts \\ []) do
    with {:ok, execution} <- execution_snapshot(project, opts),
         {:ok, input} <- Sources.analysis_input(project, source_revision_ids),
         provider_mode = String.to_existing_atom(execution["provider_mode"]),
         execution_hash = CanonicalJSON.hash(execution),
         {:ok, run} <-
           Workflow.create_run(
             project,
             "whole_novel_analysis_v1",
             %{
               "source_revision_ids" => source_revision_ids,
               "source_content_hash" => input.content_hash,
               "strategy" => "whole_document",
               "execution" => execution
             },
             "whole-novel:#{input.content_hash}:#{execution_hash}"
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
                "strategy" => "whole_document",
                "provider_mode" => Atom.to_string(provider_mode),
                "execution_hash" => execution_hash,
                "task_config" => task_config(execution, node_key)
              },
              parents
            )

          node
        end)

      {:ok, run, nodes}
    end
  end

  def execution_snapshot(%Project{} = project, opts \\ []) do
    with {:ok, provider_mode} <- provider_mode(opts) do
      {:ok, build_execution_snapshot(provider_mode, project)}
    end
  end

  defp provider_mode(opts) do
    case Keyword.get(opts, :provider_mode, Application.fetch_env!(:dramatizer, :provider_mode)) do
      mode when mode in [:fake, :openai] -> {:ok, mode}
      mode -> {:error, {:unsupported_provider_mode, mode}}
    end
  end

  defp build_execution_snapshot(:fake, _project) do
    %{
      "provider_mode" => "fake",
      "adapter" => "fixture",
      "model" => "fixture-analysis-v1",
      "workflow_schema_version" => 2
    }
  end

  defp build_execution_snapshot(:openai, project) do
    tasks =
      Map.new(@definition, fn {node_key, _parents} ->
        config = ConfigResolver.resolve(String.to_existing_atom(node_key), project)

        {node_key,
         %{
           "adapter" => config.adapter,
           "credential_ref" => config.credential_ref,
           "model" => config.model,
           "params" => config.params
         }}
      end)

    %{"provider_mode" => "openai", "tasks" => tasks, "workflow_schema_version" => 2}
  end

  defp task_config(%{"tasks" => tasks}, node_key), do: Map.fetch!(tasks, node_key)

  defp task_config(%{"provider_mode" => "fake"} = execution, _node_key) do
    %{
      "adapter" => Map.fetch!(execution, "adapter"),
      "credential_ref" => "none",
      "model" => Map.fetch!(execution, "model"),
      "params" => %{}
    }
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
