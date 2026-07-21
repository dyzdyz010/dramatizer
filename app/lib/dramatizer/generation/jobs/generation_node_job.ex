defmodule Dramatizer.Generation.Jobs.GenerationNodeJob do
  use Oban.Worker,
    queue: :generation,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Execution.WorkerLifecycle
  alias Dramatizer.Generation.Pipeline
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Workflow

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}} = job) do
    node = Workflow.get_node!(node_run_id)
    project = Projects.get_project!(project_id(node))

    case WorkerLifecycle.start(node, job) do
      {:ok, running} -> execute(running, project, job)
      {:skip, _reason} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp execute(node, project, job) do
    case Pipeline.execute_node(node, project) do
      {:ok, result} ->
        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result),
             :ok <- Pipeline.advance(completed, project) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason, details} ->
        case WorkerLifecycle.fail(node, job, reason, details) do
          {:retry, _queued, _delay} -> {:error, inspect(reason)}
          {:failed, _failed} -> Pipeline.mark_failed(node.workflow_run_id, project, node.id)
          {:cancelled, _cancelled} -> Pipeline.mark_failed(node.workflow_run_id, project, node.id)
          {:skip, _reason} -> :ok
          {:error, lifecycle_reason} -> {:error, inspect(lifecycle_reason)}
        end
    end
  end

  defp project_id(node) do
    node
    |> Repo.preload(:workflow_run)
    |> Map.fetch!(:workflow_run)
    |> Map.fetch!(:project_id)
  end
end
