defmodule Dramatizer.Analysis.Jobs.AnalysisNodeJob do
  use Oban.Worker, queue: :workflow, max_attempts: 1

  alias Dramatizer.Analysis
  alias Dramatizer.Projects
  alias Dramatizer.Workflow

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}}) do
    node = Workflow.get_node!(node_run_id)
    project = Projects.get_project!(node.input_snapshot["project_id"] || project_id(node))

    case Analysis.run_node_live(node, project) do
      {:ok, _node} -> :ok
      {:error, reason, _node} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_id(node) do
    node
    |> Dramatizer.Repo.preload(:workflow_run)
    |> Map.fetch!(:workflow_run)
    |> Map.fetch!(:project_id)
  end
end
