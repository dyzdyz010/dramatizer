defmodule Dramatizer.Execution.WorkerLifecycleTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Execution.WorkerLifecycle
  alias Dramatizer.Projects
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun

  setup do
    assert {:ok, project} = Projects.create_project(%{name: "Worker 生命周期"})
    assert {:ok, run} = Workflow.create_run(project, "worker_test", %{}, Ecto.UUID.generate())
    assert {:ok, node} = Workflow.add_node(run, "root", %{}, [])

    %{node: node}
  end

  test "queued node is acquired once and the same job may renew its lease", %{node: node} do
    job = job(10, 1, 3)

    assert {:ok, running} = WorkerLifecycle.start(node, job)
    assert running.status == :running
    assert running.active_job_id == job.id
    assert running.worker == inspect(__MODULE__)
    assert DateTime.compare(running.lease_expires_at, DateTime.utc_now()) == :gt

    assert {:ok, renewed} = WorkerLifecycle.start(running, job)
    assert renewed.id == running.id
    assert renewed.active_job_id == job.id

    assert {:skip, :owned_by_another_job} =
             WorkerLifecycle.start(renewed, job(11, 1, 3))
  end

  test "retryable failure returns node to queued until the final attempt", %{node: node} do
    first_job = job(20, 1, 3)
    assert {:ok, running} = WorkerLifecycle.start(node, first_job)

    assert {:retry, queued, delay_seconds} =
             WorkerLifecycle.fail(running, first_job, :provider_timeout)

    assert queued.status == :queued
    assert queued.active_job_id == first_job.id
    assert queued.error_code == "provider_timeout"
    assert queued.lease_expires_at == nil
    assert DateTime.compare(queued.next_retry_at, DateTime.utc_now()) == :gt
    assert delay_seconds > 0

    final_job = job(20, 3, 3)
    assert {:ok, running_again} = WorkerLifecycle.start(queued, final_job)
    assert {:failed, failed} = WorkerLifecycle.fail(running_again, final_job, :provider_timeout)
    assert failed.status == :failed
    assert failed.next_retry_at == nil
  end

  test "permanent and unknown remote failures are terminal without retry", %{node: node} do
    permanent_job = job(30, 1, 3)
    assert {:ok, running} = WorkerLifecycle.start(node, permanent_job)

    assert {:failed, failed} =
             WorkerLifecycle.fail(running, permanent_job, :invalid_proposal_output)

    assert failed.status == :failed
    assert failed.error_code == "invalid_proposal_output"

    assert {:ok, retried} = Workflow.retry_node(failed)
    unknown_job = job(31, 1, 3)
    assert {:ok, running_again} = WorkerLifecycle.start(retried, unknown_job)

    assert {:failed, unknown} =
             WorkerLifecycle.fail(running_again, unknown_job, :unknown_remote_state)

    assert unknown.status == :failed
    assert unknown.error_code == "unknown_remote_state"
  end

  test "success is terminal and stale jobs cannot complete another job's node", %{node: node} do
    current_job = job(40, 1, 3)
    assert {:ok, running} = WorkerLifecycle.start(node, current_job)

    assert {:skip, :owned_by_another_job} =
             WorkerLifecycle.succeed(running, job(41, 1, 3), %{"ignored" => true})

    assert {:ok, succeeded} =
             WorkerLifecycle.succeed(running, current_job, %{"asset_id" => "asset-1"})

    assert succeeded.status == :succeeded
    assert succeeded.result == %{"asset_id" => "asset-1"}
    assert succeeded.active_job_id == nil
    assert succeeded.lease_expires_at == nil
    assert {:skip, :terminal} = WorkerLifecycle.start(succeeded, current_job)
    assert %NodeRun{status: :succeeded} = Repo.get!(NodeRun, node.id)
  end

  defp job(id, attempt, max_attempts) do
    %Oban.Job{
      id: id,
      worker: inspect(__MODULE__),
      attempt: attempt,
      max_attempts: max_attempts,
      state: "executing",
      args: %{"node_run_id" => Ecto.UUID.generate()}
    }
  end
end
