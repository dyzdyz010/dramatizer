defmodule Dramatizer.Timeline.RenderRecipeTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.Jobs.RenderJob
  alias Dramatizer.Timeline.{RenderRecipe, SRT}
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)
    root = Path.join(System.tmp_dir!(), "dramatizer-recipe-#{System.unique_integer([:positive])}")
    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "Render Recipe"})
    narrative = Fixture.confirmed(project, :narrative, Fixture.narrative_payload())
    shot_plan = Fixture.confirmed(project, :shot_plan, Fixture.shot_plan_payload())
    {_spec, _asset, selection} = Fixture.selected_image(project, "S001", "shot:S001")

    assert {:ok, timeline} =
             Timeline.create(project, narrative, shot_plan, %{"S001" => selection})

    %{project: project, timeline: timeline}
  end

  test "SRT and preview/formal manifests are deterministic and path-specific", context do
    cues = Timeline.list_subtitles(context.timeline)
    first_srt = SRT.encode(cues)
    second_srt = SRT.encode(cues)
    assert first_srt == second_srt
    assert String.starts_with?(first_srt, "1\n00:00:00,100 --> 00:00:00,950\n你终于来了。")
    assert String.contains?(first_srt, "这封信不是我写的。")

    assert {:ok, preview1} = RenderRecipe.preview(context.timeline)
    assert {:ok, preview2} = RenderRecipe.preview(context.timeline)
    assert preview1.recipe_hash == preview2.recipe_hash
    assert preview1.width == 540
    assert preview1.height == 960
    assert preview1.input_manifest["subtitle_burn_in"] == true
    assert preview1.input_manifest["audio_mode"] == "silence_placeholder"

    assert {:ok, version} = Timeline.freeze(context.timeline)
    assert {:ok, formal} = RenderRecipe.formal(version)
    assert formal.width == 1080
    assert formal.height == 1920
    refute formal.recipe_hash == preview1.recipe_hash
    assert formal.timeline_version_id == version.id
    assert formal.render_mode == :formal
  end

  test "enqueue_render persists one id-only media job without starting FFmpeg", context do
    assert {:ok, manifest} = RenderRecipe.preview(context.timeline)
    assert manifest.status == :prepared

    assert {:ok, %{workflow_run: run, node_run: node, job: job}} =
             Timeline.enqueue_render(manifest)

    assert %WorkflowRun{status: :running} = run
    assert %NodeRun{status: :queued} = node

    assert node.input_snapshot == %{
             "render_manifest_id" => manifest.id,
             "render_mode" => "preview",
             "recipe_hash" => manifest.recipe_hash
           }

    assert job.worker == "Dramatizer.Timeline.Jobs.RenderJob"
    assert job.args == %{"node_run_id" => node.id}
    assert Repo.get!(Dramatizer.Timeline.RenderManifest, manifest.id).status == :prepared

    assert {:ok, %{workflow_run: same_run, node_run: same_node, job: same_job}} =
             Timeline.enqueue_render(manifest)

    assert same_run.id == run.id
    assert same_node.id == node.id
    assert same_job.id == job.id
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "media job insertion failure rolls back the entire render topology", context do
    assert {:ok, manifest} = RenderRecipe.preview(context.timeline)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Timeline.enqueue_render(manifest, job_options: [priority: 99])

    assert Repo.aggregate(WorkflowRun, :count) == 0
    assert Repo.aggregate(NodeRun, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "retryable render failures reset the manifest and node to one retryable aggregate",
       context do
    assert {:ok, manifest} = RenderRecipe.preview(context.timeline)

    assert {:ok, %{workflow_run: run, node_run: node, job: job}} =
             Timeline.enqueue_render(manifest)

    renderer = fn current ->
      current
      |> Dramatizer.Timeline.RenderManifest.status_changeset(%{
        status: :failed,
        technical_qc: %{},
        error_code: "temporary_file_lock"
      })
      |> Repo.update!()

      {:error, :temporary_file_lock}
    end

    assert {:error, ":temporary_file_lock"} = RenderJob.perform(job, renderer: renderer)

    assert %Dramatizer.Timeline.RenderManifest{status: :prepared, error_code: nil} =
             Repo.get!(Dramatizer.Timeline.RenderManifest, manifest.id)

    assert %NodeRun{status: :queued, error_code: "temporary_file_lock"} =
             Repo.get!(NodeRun, node.id)

    assert Repo.get!(WorkflowRun, run.id).status == :running
  end

  test "guarded render exceptions fail the manifest, node, and run together", context do
    assert {:ok, manifest} = RenderRecipe.preview(context.timeline)

    assert {:ok, %{workflow_run: run, node_run: node, job: job}} =
             Timeline.enqueue_render(manifest)

    renderer = fn current ->
      current
      |> Dramatizer.Timeline.RenderManifest.status_changeset(%{
        status: :rendering,
        technical_qc: %{},
        error_code: nil
      })
      |> Repo.update!()

      raise "private render payload"
    end

    assert :ok = RenderJob.perform(job, renderer: renderer)

    assert %Dramatizer.Timeline.RenderManifest{
             status: :failed,
             error_code: "worker_exception"
           } = Repo.get!(Dramatizer.Timeline.RenderManifest, manifest.id)

    assert %NodeRun{status: :failed, error_code: "worker_exception"} =
             Repo.get!(NodeRun, node.id)

    assert Repo.get!(WorkflowRun, run.id).status == :failed
  end
end
