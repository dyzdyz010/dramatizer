defmodule Dramatizer.Execution.ReconcilerJobTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Execution.ReconcilerJob
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun
  alias Dramatizer.Workflow.WorkflowRun
  alias Dramatizer.Workflow.Jobs.NodeJob

  test "Oban worker completes after a reconciliation pass" do
    assert :ok = ReconcilerJob.perform(%Oban.Job{})
  end

  test "extends executing jobs and preserves jobs Oban can still run" do
    {executing_run, executing_node} = create_node("executing")
    {retryable_run, retryable_node} = create_node("retryable")
    executing_job = insert_job(executing_node)
    retryable_job = insert_job(retryable_node)
    future = DateTime.add(DateTime.utc_now(), 60, :second)

    set_job_state(executing_job, "executing", DateTime.utc_now())
    set_job_state(retryable_job, "retryable", future)
    expire(executing_node, executing_job)
    expire(retryable_node, retryable_job)
    assert {:ok, executing_failed} = Workflow.mark_run(executing_run, :failed)
    assert {:ok, retryable_failed} = Workflow.mark_run(retryable_run, :failed)
    assert executing_failed.completed_at
    assert retryable_failed.completed_at

    assert {:ok, %{extended: 1, preserved: 1, requeued: 0, failed: 0}} =
             ReconcilerJob.reconcile()

    extended = Repo.get!(NodeRun, executing_node.id)
    assert extended.status == :running
    assert DateTime.compare(extended.lease_expires_at, DateTime.utc_now()) == :gt

    preserved = Repo.get!(NodeRun, retryable_node.id)
    assert preserved.status == :queued
    assert preserved.active_job_id == retryable_job.id
    assert preserved.next_retry_at == future

    assert %WorkflowRun{status: :running, completed_at: nil} =
             Repo.get!(WorkflowRun, executing_run.id)

    assert %WorkflowRun{status: :running, completed_at: nil} =
             Repo.get!(WorkflowRun, retryable_run.id)
  end

  test "requeues an orphan through its registered worker" do
    {run, node} = create_node("orphan")

    node
    |> Ecto.Changeset.change(%{
      status: :running,
      worker: inspect(NodeJob),
      active_job_id: 9_999_999,
      lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()

    assert {:ok, failed_run} = Workflow.mark_run(run, :failed)
    assert failed_run.completed_at

    assert {:ok, %{extended: 0, preserved: 0, requeued: 1, failed: 0}} =
             ReconcilerJob.reconcile()

    recovered = Repo.get!(NodeRun, node.id)
    assert recovered.status == :queued
    assert recovered.run_count == 2
    assert recovered.active_job_id != 9_999_999

    assert %Oban.Job{worker: worker, args: %{"node_run_id" => node_id}} =
             Repo.get!(Oban.Job, recovered.active_job_id)

    assert worker == inspect(NodeJob)
    assert node_id == node.id
    assert %WorkflowRun{status: :running, completed_at: nil} = Repo.get!(WorkflowRun, run.id)
  end

  test "fails exhausted or unregistered orphan nodes without executing arbitrary modules" do
    {_run, exhausted} = create_node("exhausted")
    {_run, unregistered} = create_node("unregistered")

    expire_without_job(exhausted, inspect(NodeJob), 3)
    expire_without_job(unregistered, "System", 1)

    assert {:ok, %{extended: 0, preserved: 0, requeued: 0, failed: 2}} =
             ReconcilerJob.reconcile()

    assert %NodeRun{status: :failed, error_code: "execution_retry_exhausted"} =
             Repo.get!(NodeRun, exhausted.id)

    assert %NodeRun{status: :failed, error_code: "execution_worker_unavailable"} =
             Repo.get!(NodeRun, unregistered.id)
  end

  test "ownershipless submitted nodes become unknown and fail their workflow" do
    {run, node} = create_node("submitted-orphan")
    assert {:ok, running} = Workflow.transition_node(node, :running)
    assert {:ok, _running_run} = Workflow.mark_run(run, :running)

    assert {:ok, spec} =
             Generation.create_spec(Projects.get_project!(run.project_id), %{
               kind: running.node_key,
               payload: %{"node_run_id" => running.id}
             })

    assert {:ok, _snapshot, prepared} =
             Generation.prepare_attempt(
               spec,
               :people_relations,
               Projects.get_project!(run.project_id),
               %{
                 task_override: %{
                   adapter: "fixture",
                   credential_ref: "none",
                   model: "fixture-analysis-v1"
                 },
                 node_run_id: running.id,
                 request_input: %{"input" => "fixture"},
                 prompt_snapshot: %{}
               }
             )

    assert {:ok, submitted} = Generation.transition_attempt(prepared, :submitted)

    assert {:ok, %{extended: 0, preserved: 0, requeued: 0, failed: 1}} =
             ReconcilerJob.reconcile()

    assert %Attempt{status: :unknown_remote_state, error_code: "unknown_remote_state"} =
             Repo.get!(Attempt, submitted.id)

    assert %NodeRun{status: :failed, error_code: "unknown_remote_state"} =
             Repo.get!(NodeRun, running.id)

    assert %WorkflowRun{status: :failed} = Repo.get!(WorkflowRun, run.id)
  end

  test "an already unknown provider attempt is never requeued" do
    {run, node} = create_node("unknown-attempt")

    running =
      node
      |> Ecto.Changeset.change(%{
        status: :running,
        worker: inspect(NodeJob),
        active_job_id: nil,
        lease_expires_at: nil
      })
      |> Repo.update!()

    assert {:ok, spec} =
             Generation.create_spec(Projects.get_project!(run.project_id), %{
               kind: running.node_key,
               payload: %{"node_run_id" => running.id}
             })

    assert {:ok, _snapshot, prepared} =
             Generation.prepare_attempt(
               spec,
               :people_relations,
               Projects.get_project!(run.project_id),
               %{
                 task_override: %{
                   adapter: "fixture",
                   credential_ref: "none",
                   model: "fixture-analysis-v1"
                 },
                 node_run_id: running.id,
                 request_input: %{"input" => "fixture"},
                 prompt_snapshot: %{}
               }
             )

    assert {:ok, submitted} = Generation.transition_attempt(prepared, :submitted)

    assert {:unknown_remote_state, _details} =
             Generation.reconcile_guard_failure(running, :worker_exit, %{})

    assert Repo.get!(Attempt, submitted.id).status == :unknown_remote_state

    assert {:ok, %{extended: 0, preserved: 0, requeued: 0, failed: 1}} =
             ReconcilerJob.reconcile()

    assert %Attempt{status: :unknown_remote_state} = Repo.get!(Attempt, submitted.id)

    assert %NodeRun{status: :failed, error_code: "unknown_remote_state"} =
             Repo.get!(NodeRun, running.id)

    assert %WorkflowRun{status: :failed} = Repo.get!(WorkflowRun, run.id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp create_node(key) do
    assert {:ok, project} = Projects.create_project(%{name: "恢复 #{key}"})

    assert {:ok, run} =
             Workflow.create_run(project, "reconcile_test", %{"key" => key}, Ecto.UUID.generate())

    assert {:ok, node} = Workflow.add_node(run, key, %{}, [])
    {run, node}
  end

  defp insert_job(node) do
    assert {:ok, job} = Oban.insert(NodeJob.new(%{"node_run_id" => node.id}))
    job
  end

  defp set_job_state(job, state, scheduled_at) do
    from(item in Oban.Job, where: item.id == ^job.id)
    |> Repo.update_all(set: [state: state, scheduled_at: scheduled_at])
  end

  defp expire(node, job) do
    node
    |> Ecto.Changeset.change(%{
      status: :running,
      worker: job.worker,
      active_job_id: job.id,
      lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()
  end

  defp expire_without_job(node, worker, run_count) do
    node
    |> Ecto.Changeset.change(%{
      status: :running,
      worker: worker,
      run_count: run_count,
      active_job_id: 8_000_000 + System.unique_integer([:positive]),
      lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()
  end
end
