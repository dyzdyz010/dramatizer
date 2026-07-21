defmodule Dramatizer.Execution.ReconcilerJob do
  @moduledoc "Repairs NodeRuns left behind by abnormal worker termination."

  use Oban.Worker,
    queue: :workflow,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias Dramatizer.Execution.{Notifier, WorkerRegistry}
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

    expired_ids =
      Repo.all(
        from node in NodeRun,
          where:
            node.status == :running and not is_nil(node.lease_expires_at) and
              node.lease_expires_at < ^now,
          select: node.id
      )

    counts = %{extended: 0, preserved: 0, requeued: 0, failed: 0}

    Enum.reduce_while(expired_ids, {:ok, counts}, fn node_id, {:ok, acc} ->
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
        current =
          Repo.one!(from node in NodeRun, where: node.id == ^node_id, lock: "FOR UPDATE")

        if expired?(current, now) do
          current
          |> active_job()
          |> reconcile_job(current, now)
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

  defp reconcile_job(%Oban.Job{state: "executing"}, node, now) do
    node
    |> NodeRun.transition_changeset(%{
      status: :running,
      lease_expires_at: DateTime.add(now, @lease_seconds, :second)
    })
    |> Repo.update!()

    :extended
  end

  defp reconcile_job(%Oban.Job{state: state} = job, node, _now)
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

  defp reconcile_job(_job, %NodeRun{run_count: count} = node, _now)
       when count >= @maximum_runs do
    {:ok, _failed} = transition!(node, :failed, %{error_code: "execution_retry_exhausted"})
    :failed
  end

  defp reconcile_job(_job, node, _now) do
    case WorkerRegistry.fetch(node.worker) do
      {:ok, worker} -> requeue(node, worker)
      :error -> fail_unavailable(node)
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

  defp fail_unavailable(node) do
    {:ok, _failed} =
      transition!(node, :failed, %{error_code: "execution_worker_unavailable"})

    :failed
  end

  defp transition!(node, target, attrs) do
    case Workflow.transition_locked(node, target, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp expired?(node, now) do
    node.status == :running and not is_nil(node.lease_expires_at) and
      DateTime.compare(node.lease_expires_at, now) == :lt
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
