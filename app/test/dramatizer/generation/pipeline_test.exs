defmodule Dramatizer.Generation.PipelineTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Generation
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Generation.Jobs.GenerationNodeJob
  alias Dramatizer.Generation.Pipeline
  alias Dramatizer.Execution.WorkerLifecycle
  alias Dramatizer.Projects
  alias Dramatizer.Quality.QualityReport
  alias Dramatizer.Repo
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  setup do
    previous_root = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-pipeline-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous_root)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "image pipeline persists proposal, generation, and parallel QC nodes without provider work" do
    project = project("图片流水线")
    spec = image_spec(project)

    assert {:ok, run} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)

    nodes = nodes(run)

    assert Map.keys(nodes) |> Enum.sort() ==
             ~w(asset_generation prompt_proposal semantic_qc technical_qc)

    assert nodes["prompt_proposal"].status == :queued
    assert nodes["asset_generation"].required_parent_keys == ["prompt_proposal"]
    assert nodes["technical_qc"].required_parent_keys == ["asset_generation"]
    assert nodes["semantic_qc"].required_parent_keys == ["asset_generation"]
    assert Enum.all?(Map.values(nodes), &(&1.input_snapshot["generation_spec_id"] == spec.id))
    assert Repo.aggregate(Attempt, :count) == 0

    assert [%Oban.Job{args: %{"node_run_id" => node_id}, worker: worker}] =
             Repo.all(from job in Oban.Job, where: job.worker == ^inspect(GenerationNodeJob))

    assert node_id == nodes["prompt_proposal"].id
    assert worker == inspect(GenerationNodeJob)

    assert {:ok, duplicate} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)
    assert duplicate.id == run.id
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "structured proposal pipeline stores authority in the database and queues one id-only job" do
    project = project("文本提案流水线")
    authority = %{"episode" => %{"title" => "雨夜来信"}}

    assert {:ok, %WorkflowRun{} = run} =
             Generation.enqueue_proposal(project, :narrative_proposal, authority)

    assert %{"structured_proposal" => node} = nodes(run)
    assert node.status == :queued
    assert node.input_snapshot["authority"] == authority
    assert node.input_snapshot["task_type"] == "narrative_proposal"
    assert Repo.aggregate(Attempt, :count) == 0

    assert %Oban.Job{args: %{"node_run_id" => node_id}} = Repo.get!(Oban.Job, node.active_job_id)
    assert node_id == node.id

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    completed = Repo.get!(NodeRun, node.id)
    assert completed.status == :succeeded
    assert completed.result["output"]["schema_version"] == "narrative-draft-v2"
    assert Repo.get!(WorkflowRun, run.id).status == :succeeded
    assert Repo.aggregate(Attempt, :count) == 1
  end

  test "root job insertion failure rolls back the entire generation topology" do
    project = project("图片入口回滚")
    spec = image_spec(project)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Generation.enqueue_pipeline(project, spec, :shot_keyframe,
               job_options: [priority: 99]
             )

    assert Repo.aggregate(WorkflowRun, :count) == 0
    assert Repo.aggregate(NodeRun, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a terminal root job replay repairs downstream advancement without provider work" do
    project = project("终态推进修复")
    spec = image_spec(project)
    assert {:ok, run} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)
    root = nodes(run)["prompt_proposal"]
    job = Repo.get!(Oban.Job, root.active_job_id)

    assert {:ok, running} = WorkerLifecycle.start(root, job)

    assert {:ok, _succeeded} =
             WorkerLifecycle.succeed(running, job, %{
               "provider_prompt" => "fixture",
               "provider_prompt_hash" => String.duplicate("a", 64),
               "provider_request_snapshot_id" => Ecto.UUID.generate(),
               "attempt_id" => Ecto.UUID.generate()
             })

    assert nodes(run)["asset_generation"].status == :blocked
    assert :ok = GenerationNodeJob.perform(job)

    repaired = nodes(run)["asset_generation"]
    assert repaired.status == :queued
    assert is_integer(repaired.active_job_id)
    assert Repo.get!(Oban.Job, repaired.active_job_id).worker == inspect(GenerationNodeJob)
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "a provider exception after submission becomes unknown remote at attempt and node level" do
    project = project("提交后异常")
    spec = image_spec(project)
    assert {:ok, run} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)
    root = nodes(run)["prompt_proposal"]
    job = Repo.get!(Oban.Job, root.active_job_id)

    executor = fn running_node, current_project ->
      assert {:ok, _snapshot, prepared} =
               Generation.prepare_attempt(spec, :image_prompt, current_project, %{
                 node_run_id: running_node.id,
                 task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
                 request_input: %{"input" => "fixture"}
               })

      assert {:ok, _submitted} = Generation.transition_attempt(prepared, :submitted)
      raise "private provider payload"
    end

    assert :ok = GenerationNodeJob.perform(job, executor: executor)

    assert Repo.one!(Attempt).status == :unknown_remote_state

    assert %NodeRun{status: :failed, error_code: "unknown_remote_state"} =
             Repo.get!(NodeRun, root.id)

    assert Repo.get!(WorkflowRun, run.id).status == :failed
  end

  test "image pipeline runs proposal, asset generation, and both QC branches durably" do
    project = project("可恢复图片流水线")
    spec = image_spec(project)

    assert {:ok, run} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert nodes(run)["asset_generation"].status == :queued

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    qc_jobs =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker in [
              "Dramatizer.Quality.Jobs.TechnicalQCJob",
              "Dramatizer.Quality.Jobs.SemanticQCJob"
            ]
      )

    assert length(qc_jobs) == 2
    assert Enum.all?(qc_jobs, &(Map.keys(&1.args) == ["node_run_id"]))

    assert %{failure: 0, snoozed: 0, success: 2} =
             Oban.drain_queue(queue: :qc, with_safety: false)

    completed = nodes(run)
    assert Enum.all?(completed, fn {_key, node} -> node.status == :succeeded end)
    assert Repo.get!(WorkflowRun, run.id).status == :succeeded

    assert %{
             "asset_version_id" => asset_id,
             "attempt_id" => image_attempt_id,
             "provider_request_snapshot_id" => image_snapshot_id
           } = completed["asset_generation"].result

    assert Repo.get!(AssetVersion, asset_id).lineage["generation_spec_id"] == spec.id
    assert is_binary(image_attempt_id)
    assert is_binary(image_snapshot_id)
    assert Repo.aggregate(Attempt, :count) == 2

    reports = Repo.all(from report in QualityReport, where: report.asset_version_id == ^asset_id)
    assert Enum.sort(Enum.map(reports, & &1.kind)) == [:semantic, :technical]
    assert Enum.all?(reports, &(&1.status == :pass))

    assert completed["technical_qc"].result["quality_report_id"]
    assert completed["semantic_qc"].result["quality_report_id"]
  end

  test "re-executing an asset node after a worker crash reuses the succeeded attempt" do
    project = project("图片节点崩溃恢复")
    spec = image_spec(project)
    assert {:ok, run} = Generation.enqueue_pipeline(project, spec, :shot_keyframe)

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    asset_node = nodes(run)["asset_generation"]
    assert asset_node.status == :queued

    assert {:ok, first} = Pipeline.execute_node(asset_node, project)
    assert {:ok, recovered} = Pipeline.execute_node(asset_node, project)

    assert recovered["attempt_id"] == first["attempt_id"]
    assert recovered["asset_version_id"] == first["asset_version_id"]
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(AssetVersion, :count) == 1
  end

  defp project(name) do
    assert {:ok, project} = Projects.create_project(%{name: name})
    project
  end

  defp image_spec(project) do
    assert {:ok, %GenerationSpec{} = spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{
                 "shot_id" => "S001",
                 "width" => 64,
                 "height" => 96,
                 "aspect_width" => 2,
                 "aspect_height" => 3,
                 "prompt" => "雨夜车站"
               }
             })

    spec
  end

  defp nodes(run) do
    Repo.all(from node in NodeRun, where: node.workflow_run_id == ^run.id)
    |> Map.new(&{&1.node_key, &1})
  end
end
