defmodule Dramatizer.Analysis.Runner do
  @moduledoc "Executes a persisted analysis DAG to completion through Fake or live providers."

  import Ecto.Query

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.{DAG, Fake}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  @ordered_keys Enum.map(DAG.definition(), &elem(&1, 0))

  def run(%Project{id: project_id} = project, %WorkflowRun{project_id: project_id} = run, mode) do
    with {:ok, running} <- Workflow.mark_run(run, :running),
         {:ok, snapshot} <- execute_nodes(project, running, mode),
         {:ok, _succeeded} <- Workflow.mark_run(running, :succeeded) do
      {:ok, snapshot}
    else
      {:error, _reason} = error ->
        Workflow.mark_run(Repo.get!(WorkflowRun, run.id), :failed)
        error

      {:error, reason, _node} ->
        Workflow.mark_run(Repo.get!(WorkflowRun, run.id), :failed)
        {:error, reason}
    end
  end

  defp execute_nodes(project, run, mode) do
    nodes = nodes(run.id)

    cond do
      Enum.all?(nodes, &(&1.status == :succeeded)) ->
        DAG.finalize(run)

      failed = Enum.find(nodes, &(&1.status == :failed)) ->
        {:error, {:analysis_node_failed, failed.node_key, failed.error_code}}

      queued = Enum.find(nodes, &(&1.status == :queued)) ->
        result =
          case mode do
            :fake -> Analysis.run_node(queued, project, [Fake.output(queued)])
            :openai -> Analysis.run_node_live(queued, project)
          end

        case result do
          {:ok, _completed} ->
            Workflow.queue_ready_nodes(run.id)
            execute_nodes(project, run, mode)

          error ->
            error
        end

      true ->
        {:error, :analysis_dag_blocked}
    end
  end

  defp nodes(run_id) do
    Repo.all(from node in NodeRun, where: node.workflow_run_id == ^run_id)
    |> Enum.sort_by(fn node ->
      Enum.find_index(@ordered_keys, fn key -> key == node.node_key end)
    end)
  end
end
