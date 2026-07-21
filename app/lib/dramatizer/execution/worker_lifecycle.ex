defmodule Dramatizer.Execution.WorkerLifecycle do
  @moduledoc "Owns NodeRun leases and maps worker outcomes to durable transitions."

  import Ecto.Query

  require Logger

  alias Dramatizer.Execution.{JobResult, Notifier}
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  @lease_seconds 300
  @terminal_states [:succeeded, :failed, :cancelled, :superseded]

  def start(%NodeRun{id: node_id}, %Oban.Job{id: job_id} = job)
      when is_integer(job_id) do
    result =
      Repo.transaction(fn ->
        current = lock_node(node_id)

        cond do
          current.status in @terminal_states ->
            {:skip, :terminal}

          current.status == :running and current.active_job_id == job_id ->
            {:ok, renew_lease!(current, job)}

          current.status == :running ->
            {:skip, :owned_by_another_job}

          current.status == :queued and current.active_job_id in [nil, job_id] ->
            transition!(current, :running, %{
              worker: job.worker,
              active_job_id: job_id,
              lease_expires_at: lease_expiry(),
              next_retry_at: nil
            })

          current.status == :queued ->
            {:skip, :owned_by_another_job}

          true ->
            {:skip, {:not_runnable, current.status}}
        end
      end)
      |> unwrap_transaction()

    instrument(node_id, job, result, :started)
  end

  def succeed(%NodeRun{id: node_id}, %Oban.Job{id: job_id} = job, result)
      when is_integer(job_id) and is_map(result) do
    outcome =
      Repo.transaction(fn ->
        current = lock_node(node_id)

        cond do
          current.status in @terminal_states ->
            {:skip, :terminal}

          current.active_job_id != job_id ->
            {:skip, :owned_by_another_job}

          current.status == :running ->
            transition!(current, :succeeded, %{result: result, error_code: nil})

          true ->
            {:skip, {:not_running, current.status}}
        end
      end)
      |> unwrap_transaction()

    instrument(node_id, job, outcome, :succeeded)
  end

  def fail(%NodeRun{id: node_id}, %Oban.Job{id: job_id} = job, reason)
      when is_integer(job_id) do
    outcome =
      Repo.transaction(fn ->
        current = lock_node(node_id)

        cond do
          current.status in @terminal_states ->
            {:skip, :terminal}

          current.active_job_id != job_id ->
            {:skip, :owned_by_another_job}

          current.status != :running ->
            {:skip, {:not_running, current.status}}

          true ->
            fail_locked(current, job, JobResult.classify(reason))
        end
      end)
      |> unwrap_transaction()

    instrument(node_id, job, outcome, :failed)
  end

  defp fail_locked(node, job, {:retryable, code}) when job.attempt < job.max_attempts do
    delay_seconds = backoff(job.attempt)

    {:ok, queued} =
      transition!(node, :queued, %{
        error_code: code,
        active_job_id: job.id,
        lease_expires_at: nil,
        next_retry_at: DateTime.add(DateTime.utc_now(), delay_seconds, :second)
      })

    {:retry, queued, delay_seconds}
  end

  defp fail_locked(node, _job, {:cancelled, code}) do
    {:ok, cancelled} = transition!(node, :cancelled, %{error_code: code})
    {:cancelled, cancelled}
  end

  defp fail_locked(node, _job, {_classification, code}) do
    {:ok, failed} = transition!(node, :failed, %{error_code: code})
    {:failed, failed}
  end

  defp renew_lease!(node, job) do
    node
    |> NodeRun.transition_changeset(%{
      status: :running,
      worker: job.worker,
      active_job_id: job.id,
      lease_expires_at: lease_expiry(),
      next_retry_at: nil
    })
    |> Repo.update!()
  end

  defp transition!(node, target, attrs) do
    case Workflow.transition_locked(node, target, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_node(id),
    do: Repo.one!(from node in NodeRun, where: node.id == ^id, lock: "FOR UPDATE")

  defp lease_expiry, do: DateTime.add(DateTime.utc_now(), @lease_seconds, :second)
  defp backoff(attempt), do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp instrument(node_id, job, outcome, event) do
    project_id = project_id(node_id)

    Logger.metadata(
      project_id: project_id,
      node_run_id: node_id,
      oban_job_id: job.id,
      attempt: job.attempt
    )

    Logger.debug("worker lifecycle transition", event: event, outcome: inspect(outcome))
    notify(project_id, node_id, event_for(outcome, event))
    outcome
  end

  defp project_id(node_id) do
    Repo.one!(
      from node in NodeRun,
        join: run in WorkflowRun,
        on: run.id == node.workflow_run_id,
        where: node.id == ^node_id,
        select: run.project_id
    )
  end

  defp notify(project_id, node_id, event) when is_atom(event),
    do: Notifier.broadcast(project_id, :workflow, node_id, event)

  defp event_for({:ok, _node}, event), do: event
  defp event_for({:retry, _node, _delay}, _event), do: :queued
  defp event_for({:failed, _node}, _event), do: :failed
  defp event_for({:cancelled, _node}, _event), do: :cancelled
  defp event_for(_outcome, event), do: event
end
