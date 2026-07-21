defmodule Dramatizer.Analysis.Jobs.AnalysisNodeJob do
  use Oban.Worker,
    queue: :workflow,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.DAG
  alias Dramatizer.Execution.{JobGuard, Notifier, WorkerLifecycle}
  alias Dramatizer.Generation
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
      {:ok, running} -> guarded_execute(running, project, job)
      {:skip, :terminal} -> resume_terminal(node, project)
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
        commit_success(node, project, job, result)

      {:error, reason, details} ->
        handle_failure(node, project, job, reason, details)

      {:error, reason} ->
        handle_failure(node, project, job, reason, %{})
    end
  end

  defp guarded_execute(node, project, job) do
    case JobGuard.protect(fn -> execute(node, project, job) end) do
      {:ok, result} -> result
      {:error, reason, details} -> handle_failure(node, project, job, reason, details)
    end
  end

  defp handle_failure(node, project, job, reason, details) do
    transaction =
      Repo.transaction(fn ->
        {normalized_reason, normalized_details} =
          Generation.reconcile_guard_failure(node, reason, details)

        case WorkerLifecycle.fail(node, job, normalized_reason, normalized_details, notify: false) do
          {:retry, _queued, _delay} ->
            :retry

          {terminal, _terminal_node} when terminal in [:failed, :cancelled] ->
            case mark_run_failed(node.workflow_run_id, project, node.id) do
              :ok -> :terminal
              {:error, failure_reason} -> Repo.rollback(failure_reason)
            end

          {:skip, _reason} ->
            :skip

          {:error, lifecycle_reason} ->
            Repo.rollback(lifecycle_reason)
        end
      end)

    case transaction do
      {:ok, :retry} ->
        notify_after_commit(project, node.id, :queued)
        {:error, inspect(reason)}

      {:ok, :terminal} ->
        notify_after_commit(project, node.id, :failed)
        :ok

      {:ok, :skip} ->
        :ok

      {:error, lifecycle_reason} ->
        {:error, inspect(lifecycle_reason)}
    end
  end

  defp commit_success(node, project, job, result) do
    result =
      Repo.transaction(fn ->
        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result, notify: false),
             :ok <- advance(completed, project) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        notify_after_commit(project, node.id, :succeeded)
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp resume_terminal(%NodeRun{status: :succeeded} = node, project) do
    result =
      Repo.transaction(fn ->
        case advance(node, project) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        notify_after_commit(project, node.id, :succeeded)
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp resume_terminal(%NodeRun{status: status} = node, project)
       when status in [:failed, :cancelled] do
    result =
      Repo.transaction(fn ->
        case mark_run_failed(node.workflow_run_id, project, node.id) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        notify_after_commit(project, node.id, :failed)
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp resume_terminal(%NodeRun{}, _project), do: :ok

  defp advance(node, _project) do
    with :ok <- enqueue_ready_nodes(node.workflow_run_id) do
      nodes = Repo.all(from item in NodeRun, where: item.workflow_run_id == ^node.workflow_run_id)

      if nodes != [] and Enum.all?(nodes, &(&1.status == :succeeded)) do
        run = Repo.get!(WorkflowRun, node.workflow_run_id)

        with {:ok, _snapshot} <- DAG.finalize(run),
             {:ok, _run} <- Workflow.mark_run(run, :succeeded),
             do: :ok
      else
        :ok
      end
    end
  end

  defp enqueue_ready_nodes(run_id) do
    case Enqueue.ready_nodes(run_id, fn _node -> __MODULE__ end, notify: false) do
      {:ok, _executions} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_run_failed(run_id, _project, _node_id) do
    run = Repo.get!(WorkflowRun, run_id)

    with {:ok, _run} <- Workflow.mark_run(run, :failed) do
      :ok
    end
  end

  defp notify_after_commit(project, node_id, status) do
    Notifier.broadcast(project.id, :workflow, node_id, status)
    Notifier.broadcast(project.id, :analysis, node_id, status)
  end

  defp project_id(node) do
    node
    |> Dramatizer.Repo.preload(:workflow_run)
    |> Map.fetch!(:workflow_run)
    |> Map.fetch!(:project_id)
  end
end
