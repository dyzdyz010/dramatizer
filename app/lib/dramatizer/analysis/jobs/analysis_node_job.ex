defmodule Dramatizer.Analysis.Jobs.AnalysisNodeJob do
  use Oban.Worker,
    queue: :workflow,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.DAG
  alias Dramatizer.Execution.{Notifier, WorkerLifecycle}
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}
  alias Dramatizer.Workflow.Enqueue

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}} = job) do
    node = Workflow.get_node!(node_run_id)
    project = Projects.get_project!(node.input_snapshot["project_id"] || project_id(node))

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
    mode = Application.fetch_env!(:dramatizer, :provider_mode)

    case Analysis.perform_node(node, project, mode) do
      {:ok, result} ->
        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result),
             :ok <- advance(completed, project) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason, details} ->
        handle_failure(node, project, job, reason, details)

      {:error, reason} ->
        handle_failure(node, project, job, reason, %{})
    end
  end

  defp handle_failure(node, project, job, reason, details) do
    case WorkerLifecycle.fail(node, job, reason, details) do
      {:retry, _queued, _delay} ->
        {:error, inspect(reason)}

      {:failed, _failed} ->
        mark_run_failed(node.workflow_run_id, project, node.id)
        :ok

      {:cancelled, _cancelled} ->
        mark_run_failed(node.workflow_run_id, project, node.id)
        :ok

      {:skip, _reason} ->
        :ok

      {:error, lifecycle_reason} ->
        {:error, inspect(lifecycle_reason)}
    end
  end

  defp advance(node, project) do
    with :ok <- enqueue_ready_nodes(node.workflow_run_id) do
      nodes = Repo.all(from item in NodeRun, where: item.workflow_run_id == ^node.workflow_run_id)

      if nodes != [] and Enum.all?(nodes, &(&1.status == :succeeded)) do
        run = Repo.get!(WorkflowRun, node.workflow_run_id)

        with {:ok, snapshot} <- DAG.finalize(run),
             {:ok, _run} <- Workflow.mark_run(run, :succeeded) do
          Notifier.broadcast(project.id, :analysis, snapshot.id, :succeeded)
        end
      else
        :ok
      end
    end
  end

  defp enqueue_ready_nodes(run_id) do
    run_id
    |> Workflow.queue_ready_nodes()
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case Enqueue.node(node, __MODULE__) do
        {:ok, _execution} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_run_failed(run_id, project, node_id) do
    run = Repo.get!(WorkflowRun, run_id)
    Workflow.mark_run(run, :failed)
    Notifier.broadcast(project.id, :analysis, node_id, :failed)
  end

  defp project_id(node) do
    node
    |> Dramatizer.Repo.preload(:workflow_run)
    |> Map.fetch!(:workflow_run)
    |> Map.fetch!(:project_id)
  end
end
