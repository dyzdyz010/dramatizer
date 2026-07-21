defmodule Dramatizer.Generation.Jobs.GenerationNodeJob do
  use Oban.Worker,
    queue: :generation,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Execution.{JobGuard, Notifier, WorkerLifecycle}
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Pipeline
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Workflow

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc false
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}} = job, opts) do
    node = Workflow.get_node!(node_run_id)
    project = Projects.get_project!(project_id(node))

    case WorkerLifecycle.start(node, job) do
      {:ok, running} -> guarded_execute(running, project, job, opts)
      {:skip, :terminal} -> resume_terminal(node, project)
      {:skip, _reason} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp execute(node, project, job, opts) do
    executor = Keyword.get(opts, :executor, &Pipeline.execute_node/2)

    case executor.(node, project) do
      {:ok, result} ->
        commit_success(node, project, job, result)

      {:error, reason, details} ->
        commit_failure(node, project, job, reason, details)
    end
  end

  defp guarded_execute(node, project, job, opts) do
    case JobGuard.protect(fn -> execute(node, project, job, opts) end) do
      {:ok, result} -> result
      {:error, reason, details} -> commit_failure(node, project, job, reason, details)
    end
  end

  defp commit_success(node, project, job, result) do
    transaction =
      Repo.transaction(fn ->
        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result, notify: false),
             :ok <- Pipeline.advance(completed, project, notify: false) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, project, node.id, :succeeded)
  end

  defp commit_failure(node, project, job, reason, details) do
    transaction =
      Repo.transaction(fn ->
        {normalized_reason, normalized_details} =
          Generation.reconcile_guard_failure(node, reason, details)

        case WorkerLifecycle.fail(node, job, normalized_reason, normalized_details, notify: false) do
          {:retry, _queued, _delay} ->
            :retry

          {terminal, _node} when terminal in [:failed, :cancelled] ->
            case Pipeline.mark_failed(node.workflow_run_id, project, node.id, notify: false) do
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

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{status: :succeeded} = node, project) do
    transaction =
      Repo.transaction(fn ->
        case Pipeline.advance(node, project, notify: false) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, project, node.id, :succeeded)
  end

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{status: status} = node, project)
       when status in [:failed, :cancelled] do
    transaction =
      Repo.transaction(fn ->
        case Pipeline.mark_failed(node.workflow_run_id, project, node.id, notify: false) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, project, node.id, :failed)
  end

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{}, _project), do: :ok

  defp finish_transaction({:ok, :ok}, project, node_id, status) do
    notify_after_commit(project, node_id, status)
    :ok
  end

  defp finish_transaction({:error, reason}, _project, _node_id, _status),
    do: {:error, inspect(reason)}

  defp notify_after_commit(project, node_id, status) do
    Notifier.broadcast(project.id, :workflow, node_id, status)
    Notifier.broadcast(project.id, :generation, node_id, status)
  end

  defp project_id(node) do
    node
    |> Repo.preload(:workflow_run)
    |> Map.fetch!(:workflow_run)
    |> Map.fetch!(:project_id)
  end
end
