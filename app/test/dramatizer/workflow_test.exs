defmodule Dramatizer.WorkflowTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.Enqueue
  alias Dramatizer.Workflow.{InboxMessage, NodeRun, OutboxEvent, WorkflowRun}
  alias Dramatizer.Workflow.Jobs.NodeJob

  defmodule InvalidWorker do
    def new(_args, _opts) do
      %Oban.Job{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:args, "invalid fixture")
    end
  end

  test "required parents block descendants and terminal state cannot regress" do
    assert {:ok, project} = Projects.create_project(%{name: "工作流测试"})
    assert {:ok, run} = Workflow.create_run(project, "analysis_v1", %{"source" => "r1"}, "run-1")
    assert {:ok, root} = Workflow.add_node(run, "people", %{"source" => "r1"}, [])
    assert {:ok, child} = Workflow.add_node(run, "merge", %{"parents" => ["people"]}, ["people"])
    assert root.status == :queued
    assert child.status == :blocked

    assert {:ok, running} = Workflow.transition_node(root, :running)

    assert {:ok, succeeded} =
             Workflow.transition_node(running, :succeeded, %{result: %{"count" => 3}})

    assert {:error, :invalid_transition} = Workflow.transition_node(succeeded, :running)

    assert [queued_child] = Workflow.queue_ready_nodes(run.id)
    assert queued_child.node_key == "merge"
    assert queued_child.status == :queued

    assert {:ok, child_running} = Workflow.transition_node(queued_child, :running)

    assert {:ok, failed} =
             Workflow.transition_node(child_running, :failed, %{error_code: "provider_timeout"})

    assert {:ok, retried} = Workflow.retry_node(failed)
    assert retried.status == :queued
    assert retried.run_count == 2
  end

  test "concurrent duplicate run creation and inbox delivery have one logical effect" do
    assert {:ok, project} = Projects.create_project(%{name: "幂等测试"})

    runs =
      1..8
      |> Task.async_stream(
        fn _ -> Workflow.create_run(project, "fake_v1", %{"episode" => 1}, "same-run") end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, run}} -> run end)

    assert runs |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(WorkflowRun, :count) == 1

    assert {:ok, first, :inserted} =
             Workflow.record_inbox("fake", "callback-1", %{"state" => "done"})

    assert {:ok, duplicate, :duplicate} =
             Workflow.record_inbox("fake", "callback-1", %{"state" => "done"})

    assert first.id == duplicate.id
    assert Repo.aggregate(InboxMessage, :count) == 1
  end

  test "node transitions emit one outbox event and Oban jobs carry only record ids" do
    assert {:ok, project} = Projects.create_project(%{name: "事件测试"})
    assert {:ok, run} = Workflow.create_run(project, "event_v1", %{}, "event-run")
    assert {:ok, node} = Workflow.add_node(run, "root", %{"fixed" => true}, [])
    assert {:ok, running} = Workflow.transition_node(node, :running)
    assert {:ok, _done} = Workflow.transition_node(running, :succeeded)

    assert Repo.aggregate(OutboxEvent, :count) == 2

    assert %Ecto.Changeset{changes: %{args: %{"node_run_id" => node_id}}} =
             job_changeset = NodeJob.new(%{"node_run_id" => node.id})

    assert node_id == node.id
    refute Map.has_key?(job_changeset.changes.args, "input_snapshot")

    stored = Repo.get!(NodeRun, node.id)
    assert stored.input_snapshot == %{"fixed" => true}
  end

  test "node enqueue atomically assigns one unique job with id-only args" do
    assert {:ok, project} = Projects.create_project(%{name: "原子入队"})
    assert {:ok, run} = Workflow.create_run(project, "enqueue_v1", %{}, "enqueue-run")
    assert {:ok, node} = Workflow.add_node(run, "root", %{"private" => "database"}, [])

    assert {:ok, %{node: owned, job: job}} = Enqueue.node(node, NodeJob)
    assert owned.active_job_id == job.id
    assert owned.worker == inspect(NodeJob)
    assert job.args == %{"node_run_id" => node.id}
    refute Map.has_key?(job.args, "input_snapshot")

    assert {:ok, %{node: duplicate, job: same_job}} = Enqueue.node(owned, NodeJob)
    assert duplicate.active_job_id == job.id
    assert same_job.id == job.id

    incomplete = ~w(suspended available scheduled executing retryable)

    assert Repo.aggregate(
             from(item in Oban.Job,
               where: item.worker == ^inspect(NodeJob) and item.state in ^incomplete
             ),
             :count
           ) == 1
  end

  test "job insertion failure rolls back node ownership" do
    assert {:ok, project} = Projects.create_project(%{name: "入队回滚"})
    assert {:ok, run} = Workflow.create_run(project, "enqueue_v1", %{}, "rollback-run")
    assert {:ok, node} = Workflow.add_node(run, "root", %{}, [])

    assert {:error, %Ecto.Changeset{valid?: false}} = Enqueue.node(node, InvalidWorker)

    stored = Repo.get!(NodeRun, node.id)
    assert stored.active_job_id == nil
    assert stored.worker == nil
  end
end
