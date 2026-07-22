defmodule Dramatizer.Execution.ReconcilerJob do
  @moduledoc "Repairs NodeRuns left behind by abnormal worker termination."

  use Oban.Worker,
    queue: :workflow,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias Dramatizer.Execution.{Notifier, WorkerRegistry}
  alias Dramatizer.Generation
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  @lease_seconds 300
  @maximum_runs 3
  @runnable_job_states ~w(available scheduled retryable suspended)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case reconcile() do
      {:ok, _counts} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def reconcile do
    now = DateTime.utc_now()

    recoverable_ids =
      Repo.all(
        from node in NodeRun,
          where:
            node.status == :running and
              (is_nil(node.worker) or is_nil(node.active_job_id) or
                 is_nil(node.lease_expires_at) or node.lease_expires_at < ^now),
          select: node.id
      )

    counts = %{extended: 0, preserved: 0, requeued: 0, failed: 0}

    Enum.reduce_while(recoverable_ids, {:ok, counts}, fn node_id, {:ok, acc} ->
      case reconcile_node(node_id, now) do
        {:ok, :unchanged} -> {:cont, {:ok, acc}}
        {:ok, outcome} -> {:cont, {:ok, Map.update!(acc, outcome, &(&1 + 1))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_node(node_id, now) do
    result =
      Repo.transaction(fn ->
        snapshot = Repo.get!(NodeRun, node_id)
        run = lock_run(snapshot.workflow_run_id)

        current =
          Repo.one!(from node in NodeRun, where: node.id == ^node_id, lock: "FOR UPDATE")

        if recoverable?(current, now) do
          outcome =
            current
            |> active_job()
            |> reconcile_job(current, run, now)

          resume_run_if_needed!(run, outcome)
          outcome
        else
          :unchanged
        end
      end)

    case result do
      {:ok, outcome} ->
        maybe_notify(node_id, outcome)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp active_job(%NodeRun{active_job_id: nil}), do: nil
  defp active_job(%NodeRun{active_job_id: id}), do: Repo.get(Oban.Job, id)

  defp reconcile_job(%Oban.Job{state: "executing"}, node, _run, now) do
    node
    |> NodeRun.transition_changeset(%{
      status: :running,
      lease_expires_at: DateTime.add(now, @lease_seconds, :second)
    })
    |> Repo.update!()

    :extended
  end

  defp reconcile_job(%Oban.Job{state: state} = job, node, _run, _now)
       when state in @runnable_job_states do
    {:ok, _queued} =
      transition!(node, :queued, %{
        worker: job.worker,
        active_job_id: job.id,
        lease_expires_at: nil,
        next_retry_at: job.scheduled_at
      })

    :preserved
  end

  defp reconcile_job(_job, node, run, _now) do
    case Generation.reconcile_guard_failure(node, :worker_exit, %{
           "reason" => "execution_ownership_lost"
         }) do
      {:unknown_remote_state, details} ->
        fail_node(node, run, "unknown_remote_state", details)

      {_reason, _details} when node.run_count >= @maximum_runs ->
        fail_node(node, run, "execution_retry_exhausted", %{})

      {_reason, _details} ->
        case WorkerRegistry.fetch(node.worker) do
          {:ok, worker} -> requeue(node, worker)
          :error -> fail_unavailable(node, run)
        end
    end
  end

  defp requeue(node, worker) do
    changeset =
      worker.new(%{"node_run_id" => node.id},
        unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]
      )

    case Oban.insert(changeset) do
      {:ok, job} ->
        {:ok, _queued} =
          transition!(node, :queued, %{
            worker: job.worker,
            active_job_id: job.id,
            lease_expires_at: nil,
            next_retry_at: nil,
            run_count: node.run_count + 1,
            error_code: "execution_recovered"
          })

        :requeued

      {:error, changeset} ->
        Repo.rollback({:job_insert_failed, changeset})
    end
  end

  defp fail_unavailable(node, run) do
    fail_node(node, run, "execution_worker_unavailable", %{})
  end

  defp fail_node(node, run, error_code, details) do
    {:ok, _failed} =
      transition!(node, :failed, %{error_code: error_code, result: details})

    {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    :failed
  end

  defp transition!(node, target, attrs) do
    case Workflow.transition_locked(node, target, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_run_if_needed!(run, outcome) when outcome in [:extended, :preserved, :requeued] do
    case Workflow.mark_run(run, :running) do
      {:ok, _running} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_run_if_needed!(_run, _outcome), do: :ok

  defp lock_run(run_id) do
    Repo.one!(
      from run in WorkflowRun,
        where: run.id == ^run_id,
        lock: "FOR UPDATE"
    )
  end

  defp recoverable?(node, now) do
    node.status == :running and
      (is_nil(node.worker) or is_nil(node.active_job_id) or is_nil(node.lease_expires_at) or
         DateTime.compare(node.lease_expires_at, now) == :lt)
  end

  defp maybe_notify(_node_id, :unchanged), do: :ok

  defp maybe_notify(node_id, outcome) do
    project_id =
      Repo.one!(
        from node in NodeRun,
          join: run in WorkflowRun,
          on: run.id == node.workflow_run_id,
          where: node.id == ^node_id,
          select: run.project_id
      )

    Notifier.broadcast(project_id, :workflow, node_id, outcome)
  end
end
