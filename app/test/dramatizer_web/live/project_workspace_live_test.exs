defmodule DramatizerWeb.ProjectWorkspaceLiveTest do
  use DramatizerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Analysis.{AnalysisSnapshot, DAG}
  alias Dramatizer.Analysis.Jobs.AnalysisNodeJob
  alias Dramatizer.Projects
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Revisions.Draft
  alias Dramatizer.Sources
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline.{Clip, RenderManifest, SubtitleCue, Timeline}
  alias Dramatizer.Workflow.InboxMessage
  alias Dramatizer.Workflow
  alias Dramatizer.Repo
  alias DramatizerWeb.ProjectWorkspace.Subscription
  alias DramatizerWeb.Live.Components.RunPanel

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)
    root = Path.join(System.tmp_dir!(), "dramatizer-live-#{System.unique_integer([:positive])}")
    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "网页制作流"})
    %{project: project}
  end

  test "every stage route renders persistent context and a truthful initial state", %{
    conn: conn,
    project: project
  } do
    expected = %{
      "source" => "empty",
      "analysis" => "waiting_user",
      "episodes" => "waiting_user",
      "visuals" => "waiting_user",
      "shots" => "waiting_user",
      "timeline" => "waiting_user",
      "runs" => "empty"
    }

    for {stage, state} <- expected do
      {:ok, view, html} = live(conn, "/projects/#{project.id}/#{stage}")
      assert html =~ project.name
      assert has_element?(view, "[data-stage='#{stage}'][data-state='#{state}']")
      assert has_element?(view, "nav[aria-label='制作阶段']")
    end
  end

  test "execution notifications route only to their affected workspace slices" do
    assert Subscription.slice_for(%{resource: :analysis}) == :analysis
    assert Subscription.slice_for(%{resource: :generation}) == :generation
    assert Subscription.slice_for(%{resource: :quality}) == :generation
    assert Subscription.slice_for(%{resource: :timeline}) == :timeline
    assert Subscription.slice_for(%{resource: :workflow}) == :execution
    assert Subscription.slice_for(%{resource: :unexpected}) == :ignore
  end

  test "failed analysis nodes retry through the analysis worker without crashing LiveView", %{
    conn: conn,
    project: project
  } do
    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)
    assert {:ok, run, nodes} = DAG.start(project, [source.id])
    root = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(root, :running)

    assert {:ok, failed} =
             Workflow.transition_node(running, :failed, %{error_code: "provider_failed"})

    assert failed.worker == nil
    assert {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/analysis")
    render_click(view, "retry-node", %{"id" => failed.id})

    recovered = Repo.get!(Workflow.NodeRun, failed.id)
    assert recovered.status == :queued
    assert recovered.worker == inspect(AnalysisNodeJob)
    assert is_integer(recovered.active_job_id)
    assert Repo.get!(Workflow.WorkflowRun, run.id).status == :running
  end

  test "legacy active analysis does not block a new Fake execution identity", %{
    conn: conn,
    project: project
  } do
    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)

    assert {:ok, legacy_run} =
             Workflow.create_run(
               project,
               "whole_novel_analysis_v1",
               %{
                 "source_revision_ids" => [source.id],
                 "source_content_hash" => source.content_hash,
                 "strategy" => "whole_document"
               },
               "legacy-analysis"
             )

    assert {:ok, _legacy_running} = Workflow.mark_run(legacy_run, :running)

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/analysis")
    refute has_element?(view, "button[phx-click='start-analysis'][disabled]")

    render_click(view, "start-analysis", %{})

    assert Repo.aggregate(
             from(run in Workflow.WorkflowRun,
               where:
                 run.project_id == ^project.id and
                   run.definition_key == "whole_novel_analysis_v1"
             ),
             :count
           ) == 2
  end

  test "an active analysis with stale same-provider config does not block a new run", %{
    conn: conn,
    project: project
  } do
    previous_mode = Application.fetch_env!(:dramatizer, :provider_mode)
    Application.put_env(:dramatizer, :provider_mode, :openai)
    on_exit(fn -> Application.put_env(:dramatizer, :provider_mode, previous_mode) end)

    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)

    assert {:ok, _override} =
             Projects.put_model_override(project, :people_relations, %{model: "gpt-config-a"})

    assert {:ok, first_run} =
             Dramatizer.Analysis.enqueue(project, [source.id], provider_mode: :openai)

    assert first_run.status == :running

    assert {:ok, _override} =
             Projects.put_model_override(project, :people_relations, %{model: "gpt-config-b"})

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/analysis")
    refute has_element?(view, "button[phx-click='start-analysis'][disabled]")
  end

  test "historical failed analysis nodes do not override the latest successful analysis", %{
    conn: conn,
    project: project
  } do
    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)

    assert {:ok, old_run} =
             Workflow.create_run(
               project,
               "whole_novel_analysis_v1",
               %{"source_revision_ids" => [source.id]},
               "old-analysis-failure"
             )

    assert {:ok, old_node} = Workflow.add_node(old_run, "people_relations", %{}, [])
    assert {:ok, old_running} = Workflow.transition_node(old_node, :running)

    assert {:ok, _old_failed} =
             Workflow.transition_node(old_running, :failed, %{error_code: "provider_failed"})

    assert {:ok, _old_failed_run} = Workflow.mark_run(old_run, :failed)

    assert {:ok, _new_run} = Dramatizer.Analysis.enqueue(project, [source.id])

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/analysis")
    assert has_element?(view, "[data-stage='analysis'][data-state='ready']")
  end

  test "a latest failed analysis run cannot appear ready from an older snapshot", %{
    conn: conn,
    project: project
  } do
    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)
    assert {:ok, successful_run} = Dramatizer.Analysis.enqueue(project, [source.id])

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    assert Repo.get_by!(AnalysisSnapshot, workflow_run_id: successful_run.id)

    assert {:ok, latest_run} =
             Workflow.create_run(
               project,
               "whole_novel_analysis_v1",
               %{
                 "source_revision_ids" => [source.id],
                 "execution" => %{"provider_mode" => "fake", "revision" => 2}
               },
               "latest-analysis-failure"
             )

    assert {:ok, _latest_failed} = Workflow.mark_run(latest_run, :failed)

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/analysis")
    assert has_element?(view, "[data-stage='analysis'][data-state='failed']")
    refute has_element?(view, "[data-stage='analysis'][data-state='ready']")
    refute has_element?(view, "[data-analysis-group]")

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    refute has_element?(episodes, "button[phx-click='select-episode']")

    render_click(episodes, "select-episode", %{"candidate-id" => "episode:001"})
    assert render(episodes) =~ "请先完成全文分析"

    assert Repo.aggregate(
             from(run in Workflow.WorkflowRun,
               where:
                 run.project_id == ^project.id and
                   run.definition_key == "structured_proposal_v1"
             ),
             :count
           ) == 0
  end

  test "a mounted episodes page drops old candidates as soon as a newer analysis is enqueued", %{
    conn: conn,
    project: project
  } do
    fixture = Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
    assert {:ok, _document, source} = Sources.import(project, fixture)
    assert {:ok, _successful_run} = Dramatizer.Analysis.enqueue(project, [source.id])

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    assert has_element?(episodes, "button[phx-click='select-episode']")

    assert {:ok, newer_run} =
             Dramatizer.Analysis.enqueue(project, [source.id], provider_mode: :openai)

    assert newer_run.status == :running
    refute has_element?(episodes, "button[phx-click='select-episode']")

    render_click(episodes, "select-episode", %{"candidate-id" => "episode:001"})
    assert render(episodes) =~ "请先完成全文分析"

    assert Repo.aggregate(
             from(run in Workflow.WorkflowRun,
               where:
                 run.project_id == ^project.id and
                   run.definition_key == "structured_proposal_v1"
             ),
             :count
           ) == 0
  end

  test "run center distinguishes queued work from unknown remote outcomes" do
    html =
      render_component(&RunPanel.run_panel/1,
        runs: [
          %{
            status: :pending,
            definition_key: "image_generation_v1",
            graph_epoch: 1,
            started_at: nil,
            completed_at: nil
          }
        ],
        attempts: [
          %{
            status: :unknown_remote_state,
            task_type: "shot_keyframe",
            adapter: "openai",
            model: "gpt-image-2",
            attempt_number: 1,
            spec_id: Ecto.UUID.generate(),
            error_code: "unknown_remote_state"
          }
        ],
        costs: []
      )

    assert html =~ ~s(data-state="queued")
    assert html =~ ~s(data-state="unknown")
    assert html =~ "远端状态未知"
    assert html =~ "禁止自动重提"
  end

  test "historical failed attempts do not override a recovered workflow state", %{
    conn: conn,
    project: project
  } do
    assert {:ok, spec} =
             Dramatizer.Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{"shot_id" => "history"}
             })

    assert {:ok, _snapshot, prepared} =
             Dramatizer.Generation.prepare_attempt(spec, :shot_keyframe, project, %{
               task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
               request_input: %{"generation_spec" => spec.payload}
             })

    assert {:ok, submitted} = Dramatizer.Generation.transition_attempt(prepared, :submitted)

    assert {:ok, _failed_attempt} =
             Dramatizer.Generation.transition_attempt(submitted, :failed, %{
               error_code: "provider_rejected"
             })

    run_input = %{"generation_spec_id" => spec.id, "task_type" => "shot_keyframe"}

    assert {:ok, old_run} =
             Workflow.create_run(project, "image_generation_v1", run_input, "old-failed-history")

    assert {:ok, old_node} = Workflow.add_node(old_run, "asset_generation", run_input, [])
    assert {:ok, old_running_node} = Workflow.transition_node(old_node, :running)

    assert {:ok, _old_failed_node} =
             Workflow.transition_node(old_running_node, :failed, %{
               error_code: "provider_rejected"
             })

    assert {:ok, _old_failed_run} = Workflow.mark_run(old_run, :failed)

    assert {:ok, run} =
             Workflow.create_run(project, "image_generation_v1", run_input, "recovered-history")

    assert {:ok, node} = Workflow.add_node(run, "asset_generation", run_input, [])
    assert {:ok, running_node} = Workflow.transition_node(node, :running)
    assert {:ok, _succeeded_node} = Workflow.transition_node(running_node, :succeeded)
    assert {:ok, _succeeded_run} = Workflow.mark_run(run, :succeeded)

    {:ok, view, _html} = live(conn, "/projects/#{project.id}/runs")
    assert has_element?(view, "[data-stage='runs'][data-state='ready']")
    assert has_element?(view, "a[href$='/shots'][data-stage-state='waiting_user']")
  end

  test "workspace uses non-color state labels in the stage rail and canvas", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/projects/#{project.id}/runs")
    assert has_element?(view, "aside[aria-label='制作阶段'] [data-stage-state='empty']")
    assert has_element?(view, "main[data-workspace-canvas][data-state='empty']")
    assert render(view) =~ "未开始"
  end

  test "workspace shell exposes the rail, provider header, inspector, and next action", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/projects/#{project.id}/source")
    assert has_element?(view, "aside[aria-label='制作阶段']")
    assert has_element?(view, "header [data-provider-mode]")
    assert has_element?(view, "main[data-workspace-canvas]")
    assert has_element?(view, "aside[data-inspector]")
    assert has_element?(view, "[data-next-action]")
  end

  test "project settings expose editable profile, model overrides, appendices, and rename", %{
    conn: conn,
    project: project
  } do
    assert {:ok, reservation} = Costs.reserve(project, 0, "ui-unknown-cost")
    assert {:ok, _actual} = Costs.settle(reservation, nil, %{provider: "openai"})

    {:ok, runs, html} = live(conn, "/projects/#{project.id}/runs")
    refute html =~ "中文权威视觉数据到图像 Provider 提示词的受控编译器"
    assert html =~ "实际费用未返回"

    runs
    |> form("#production-profile-form",
      profile: %{
        aspect_width: "9",
        aspect_height: "16",
        duration_min_seconds: "75",
        duration_max_seconds: "105",
        shot_min: "12",
        shot_max: "24",
        preview_width: "540",
        preview_height: "960",
        formal_width: "1080",
        formal_height: "1920"
      }
    )
    |> render_submit()

    profile = Projects.effective_profile(project)
    assert profile.duration_min_seconds == 75
    assert profile.shot_max == 24

    runs
    |> form("#model-override-form",
      model_override: %{
        task_type: "shot_keyframe",
        model: "gpt-image-2",
        candidate_count: "3",
        quality: "high",
        size: "768x1360"
      }
    )
    |> render_submit()

    override = Projects.model_override(project, :shot_keyframe)
    assert override.model == "gpt-image-2"
    assert override.params["candidate_count"] == 3
    assert override.params["quality"] == "high"

    runs
    |> form("#prompt-appendix-form",
      prompt_appendix: %{
        task_type: "image_prompt",
        body: "加强人物与场景可生成细节，但保持中文权威数据。"
      }
    )
    |> render_submit()

    appendix = Projects.current_prompt_appendix(project, :image_prompt)
    assert appendix.revision == 1
    assert appendix.body =~ "可生成细节"

    runs
    |> form("#rename-project-form", project: %{name: "网页制作流·修订"})
    |> render_submit()

    assert Projects.get_project!(project.id).name == "网页制作流·修订"
    assert render(runs) =~ "网页制作流·修订"
  end

  test "direct LiveView text upload queues analysis, survives remount, and refreshes on PubSub",
       %{
         conn: conn,
         project: project
       } do
    {:ok, view, _html} = live(conn, "/projects/#{project.id}/source")

    upload =
      file_input(view, "#source-upload-form", :source, [
        %{name: "novel.txt", content: "第一章\n雨夜里，她收到一封信。", type: "text/plain"}
      ])

    assert render_upload(upload, "novel.txt") =~ "novel.txt"
    view |> form("#source-upload-form") |> render_submit()

    assert_patch(view, "/projects/#{project.id}/analysis")
    assert render(view) =~ "分析审阅"
    assert Repo.get_by!(SourceRevision, project_id: project.id).character_count > 0
    refute Repo.get_by(AnalysisSnapshot, project_id: project.id)
    assert render(view) =~ "已加入队列"
    assert Repo.aggregate(Oban.Job, :count) == 3

    {:ok, remounted, _html} = live(conn, "/projects/#{project.id}/analysis")
    assert has_element?(remounted, "[data-stage='analysis'][data-state='loading']")
    assert has_element?(remounted, ".dag-node [data-state='queued']")

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    assert Repo.get_by!(AnalysisSnapshot, project_id: project.id)
    assert has_element?(remounted, "[data-stage='analysis'][data-state='ready']")
  end

  test "project settings expose the provider and typed model controls without JSON", %{
    conn: conn,
    project: project
  } do
    {:ok, view, html} = live(conn, "/projects/#{project.id}/runs")

    assert html =~ "当前运行模式"
    assert has_element?(view, "[data-provider-mode='fake']")
    refute html =~ "参数 JSON"
    refute has_element?(view, "textarea[name='model_override[params]']")
    assert has_element?(view, "select[name='model_override[quality]']")
    assert has_element?(view, "input[name='budget[limit_units]']")
  end

  test "source import cannot report success without a completed upload", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/projects/#{project.id}/source")

    view |> form("#source-upload-form") |> render_submit()

    refute render(view) =~ "原著已按全文解析并落盘。"
    assert render(view) =~ "请先选择文件并等待上传完成。"
    refute Repo.get_by(SourceRevision, project_id: project.id)
  end

  test "workspace exposes explicit human gates and never auto-selects candidates", %{
    conn: conn,
    project: project
  } do
    for stage <- ~w(episodes visuals shots timeline) do
      {:ok, view, _html} = live(conn, "/projects/#{project.id}/#{stage}")
      assert has_element?(view, "[data-human-gate]")
      refute has_element?(view, "input[checked][name='candidate']")
    end
  end

  test "automatic full-text analysis exposes candidates and creates a rich Narrative form", %{
    conn: conn,
    project: project
  } do
    {:ok, source_view, _html} = live(conn, "/projects/#{project.id}/source")

    upload =
      file_input(source_view, "#source-upload-form", :source, [
        %{name: "story.md", content: "# 雨夜来信\n林夏在车站收到一封匿名信。", type: "text/markdown"}
      ])

    render_upload(upload, "story.md")
    source_view |> form("#source-upload-form") |> render_submit()

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    {:ok, analysis, _html} = live(conn, "/projects/#{project.id}/analysis")
    assert has_element?(analysis, "[data-stage='analysis'][data-state='ready']")
    assert has_element?(analysis, ".dag-node [data-state='ready']")
    assert has_element?(analysis, "[data-analysis-review]")
    assert render(analysis) =~ "人物与关系"
    assert render(analysis) =~ "地点、道具与世界"

    {:ok, episodes, html} = live(conn, "/projects/#{project.id}/episodes")
    assert html =~ "雨夜来信"
    assert has_element?(episodes, "button[phx-click='select-episode']")

    render_click(episodes, "select-episode", %{"candidate-id" => "episode:001"})
    refute Repo.get_by(Draft, project_id: project.id, kind: :narrative, status: :editing)
    assert render(episodes) =~ "已加入队列"

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "Dramatizer.Generation.Jobs.GenerationNodeJob" and
                   job.state in ["available", "scheduled", "executing", "retryable"]
             ),
             :count
           ) == 1

    render_click(episodes, "select-episode", %{"candidate-id" => "episode:001"})

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "Dramatizer.Generation.Jobs.GenerationNodeJob" and
                   job.state in ["available", "scheduled", "executing", "retryable"]
             ),
             :count
           ) == 1

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    html = render(episodes)
    assert html =~ "分集概览"
    assert html =~ "Scene"
    assert has_element?(episodes, "form[phx-submit='save-narrative-draft']")
    refute html =~ "结构化内容"
    refute has_element?(episodes, "textarea[name='draft[payload]']")

    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

    refute Repo.get_by(Draft,
             project_id: project.id,
             kind: :visual_design,
             status: :editing
           )

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert Repo.get_by!(Draft,
             project_id: project.id,
             kind: :visual_design,
             status: :editing
           )

    {:ok, visuals, visual_html} = live(conn, "/projects/#{project.id}/visuals")
    assert visual_html =~ "角色"
    assert visual_html =~ "场景"
    assert visual_html =~ "道具"
    assert visual_html =~ "视觉 Variant"
    assert has_element?(visuals, "form[phx-submit='save-visual-design-draft']")
    refute visual_html =~ "角色／场景／道具对象 JSON"
  end

  test "browser-visible Fake fault control resumes without duplicate result or cost", %{
    conn: conn,
    project: project
  } do
    {:ok, runs, _html} = live(conn, "/projects/#{project.id}/runs")
    runs |> element("button", "注入一次 Fake 失败") |> render_click()
    assert Repo.aggregate(Attempt, :count) == 0

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert Repo.one!(
             from attempt in Attempt,
               join: request in assoc(attempt, :provider_request_snapshot),
               where: request.task_type == "shot_keyframe",
               select: attempt.status
           ) == :failed

    runs |> element("button", "恢复并注入重复乱序回调") |> render_click()
    drain_generation_pipeline()
    assert Repo.aggregate(Attempt, :count) == 3
    assert Repo.aggregate(AssetVersion, :count) == 1
    assert Repo.aggregate(InboxMessage, :count) == 1
    assert Repo.aggregate(from(cost in CostEntry, where: cost.entry_type == :actual), :count) == 1
    assert has_element?(runs, "[data-stage='runs'][data-state='ready']")
    assert has_element?(runs, "a[href$='/shots'][data-stage-state='waiting_user']")

    runs |> element("button", "恢复并注入重复乱序回调") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 0} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert Repo.aggregate(Attempt, :count) == 3
    assert Repo.aggregate(AssetVersion, :count) == 1
    assert Repo.aggregate(from(cost in CostEntry, where: cost.entry_type == :actual), :count) == 1
  end

  @tag timeout: 180_000
  test "visual workspace generates reference candidates, records explicit choices, and edits immutably",
       %{conn: conn, project: project} do
    {:ok, source, _html} = live(conn, "/projects/#{project.id}/source")
    upload_text(source, "reference-story.txt", "林夏在雨夜车站打开一封匿名信。")

    {:ok, analysis, _html} = live(conn, "/projects/#{project.id}/analysis")
    render_click(analysis, "start-analysis", %{})

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    episodes |> element("button[phx-click='select-episode']") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    {:ok, visuals, _html} = live(conn, "/projects/#{project.id}/visuals")

    visual = Repo.get_by!(Draft, project_id: project.id, kind: :visual_design, status: :editing)
    visuals |> element("button[phx-value-id='#{visual.id}']", "确认并冻结") |> render_click()
    visuals |> element("button", "AI 生成参考候选") |> render_click()

    refute Repo.exists?(
             from asset in AssetVersion,
               where: asset.project_id == ^project.id and asset.kind == "reference_image"
           )

    drain_generation_pipeline()

    required_slots =
      for object <- visual.payload["objects"],
          object["reference_required"],
          variant <- object["variants"],
          slot <- variant["required_slots"] do
        "#{object["id"]}/#{variant["id"]}/#{slot}"
      end

    assert Repo.aggregate(
             from(spec in GenerationSpec,
               where: spec.project_id == ^project.id and spec.kind == "reference_image"
             ),
             :count
           ) == length(required_slots) * 4

    assert has_element?(visuals, ".candidate-card")
    candidate_html = render(visuals)
    assert candidate_html =~ "选择为主图"
    assert candidate_html =~ "再次生成"
    assert candidate_html =~ "基于此图编辑"
    assert candidate_html =~ "返回上游修改"
    assert candidate_html =~ "角色身份与 Variant"

    for slot <- required_slots do
      visuals
      |> element(
        "button[phx-click='select-candidate'][phx-value-slot-key='reference:#{slot}'][data-candidate-index='0']",
        "选择为主图"
      )
      |> render_click()
    end

    visuals |> element("button", "从已选主图创建 ReferenceSet") |> render_click()

    assert Repo.get_by!(Draft,
             project_id: project.id,
             kind: :reference_set,
             status: :editing
           )

    parent =
      Repo.one!(
        from asset in AssetVersion,
          where: asset.project_id == ^project.id and asset.kind == "reference_image",
          order_by: [asc: asset.inserted_at],
          limit: 1
      )

    visuals
    |> form("#edit-candidate-#{parent.id}", edit: %{instruction: "信封边缘增加雨水浸湿痕迹"})
    |> render_submit()

    drain_generation_pipeline()

    child =
      Repo.one!(
        from asset in AssetVersion,
          where: asset.parent_asset_id == ^parent.id,
          order_by: [desc: asset.inserted_at],
          limit: 1
      )

    assert child.blob_hash != parent.blob_hash
    assert child.lineage["parent_asset_id"] == parent.id
    assert Assets.get_asset!(parent.id).blob_hash == parent.blob_hash
  end

  @tag timeout: 180_000
  test "all primary human gates reach a rendered formal animatic through LiveView", %{
    conn: conn,
    project: project
  } do
    {:ok, source, _html} = live(conn, "/projects/#{project.id}/source")
    upload_text(source, "novel.txt", "雨夜里，林夏收到一封匿名信。")

    {:ok, analysis, _html} = live(conn, "/projects/#{project.id}/analysis")
    render_click(analysis, "start-analysis", %{})

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    episodes |> element("button[phx-click='select-episode']") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    {:ok, visuals, _html} = live(conn, "/projects/#{project.id}/visuals")
    visual = Repo.get_by!(Draft, project_id: project.id, kind: :visual_design, status: :editing)
    visuals |> element("button[phx-value-id='#{visual.id}']", "确认并冻结") |> render_click()

    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => 270,
        "height" => 480,
        "seed" => "live-reference"
      })

    image_upload =
      file_input(visuals, "#media-upload-form", :media, [
        %{
          name: "reference.png",
          content: Base.decode64!(generated["png_base64"]),
          type: "image/png"
        }
      ])

    render_upload(image_upload, "reference.png")
    visuals |> form("#media-upload-form") |> render_submit()
    asset = Repo.get_by!(AssetVersion, project_id: project.id, kind: "user-reference")

    assignments =
      visuals
      |> render()
      |> then(fn _html -> reference_assignments(project.id, asset.id) end)

    visuals
    |> form("#reference-set-form", reference: %{assignments: assignments})
    |> render_submit()

    reference =
      Repo.get_by!(Draft, project_id: project.id, kind: :reference_set, status: :editing)

    visuals |> element("button[phx-value-id='#{reference.id}']", "确认并冻结") |> render_click()

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :generation, with_safety: false)

    assert Repo.get_by!(Draft, project_id: project.id, kind: :shot_plan, status: :editing)

    {:ok, shots, shot_html} = live(conn, "/projects/#{project.id}/shots")
    assert shot_html =~ "呈现目标"
    assert shot_html =~ "连续性"
    assert has_element?(shots, "form[phx-submit='save-shot-plan-draft']")
    refute shot_html =~ "ShotPlan JSON"
    shot_plan = Repo.get_by!(Draft, project_id: project.id, kind: :shot_plan, status: :editing)
    shots |> element("button[phx-value-id='#{shot_plan.id}']", "确认并冻结") |> render_click()
    shots |> element("button", "编译冻结 GenerationSpec") |> render_click()
    shots |> element("button", "生成候选并执行 QC") |> render_click()
    drain_generation_pipeline()
    assert has_element?(shots, ".candidate-card")

    refute Repo.exists?(
             from selection in SelectionDecision, where: selection.project_id == ^project.id
           )

    candidate =
      Repo.one!(
        from asset in AssetVersion,
          where: asset.project_id == ^project.id and asset.kind == "shot_keyframe",
          order_by: [asc: asset.inserted_at],
          limit: 1
      )

    shots
    |> element("button[phx-click='select-candidate'][phx-value-asset-id='#{candidate.id}']")
    |> render_click()

    assert Repo.exists?(
             from selection in SelectionDecision, where: selection.project_id == ^project.id
           )

    {:ok, timeline_view, _html} = live(conn, "/projects/#{project.id}/timeline")
    timeline_view |> element("button", "从已确认输入创建") |> render_click()
    timeline_html = render(timeline_view)
    assert timeline_html =~ "AAC 双声道静音占位"
    assert has_element?(timeline_view, "[data-render-path='preview']")
    assert has_element?(timeline_view, "[data-render-path='formal']")

    timeline_view |> element("button", "生成预览") |> render_click()
    preview = Repo.get_by!(RenderManifest, project_id: project.id, render_mode: :preview)
    assert preview.status == :prepared
    assert render(timeline_view) =~ "预览渲染已加入队列"

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :media, with_safety: false)

    assert Repo.get!(RenderManifest, preview.id).status == :rendered

    timeline = Repo.get_by!(Timeline, project_id: project.id)
    first_clip = Repo.one!(from clip in Clip, where: clip.timeline_id == ^timeline.id, limit: 1)

    timeline_view
    |> form("#clip-#{first_clip.id}",
      clip: %{
        duration_ms: "2350",
        motion: "pan_right",
        transition_after: "cross_dissolve",
        transition_duration_ms: "500"
      }
    )
    |> render_submit()

    edited_clip = Repo.get!(Clip, first_clip.id)
    assert edited_clip.duration_ms == 2350
    assert edited_clip.motion == :pan_right
    assert edited_clip.transition_after == :cross_dissolve
    assert edited_clip.transition_duration_ms == 500

    first_cue =
      Repo.one!(from cue in SubtitleCue, where: cue.timeline_id == ^timeline.id, limit: 1)

    timeline_view
    |> form("#subtitle-#{first_cue.id}",
      cue: %{text: "字幕已细调。", start_ms: "200", end_ms: "1500", position: "safe_top"}
    )
    |> render_submit()

    edited_cue = Repo.get!(SubtitleCue, first_cue.id)
    assert edited_cue.text == "字幕已细调。"
    assert edited_cue.start_ms == 200
    assert edited_cue.end_ms == 1500
    assert edited_cue.style["position"] == "safe_top"

    timeline_view |> element("button", "添加占位镜头") |> render_click()

    assert Repo.aggregate(from(clip in Clip, where: clip.timeline_id == ^timeline.id), :count) ==
             4

    timeline_view |> element("button", "冻结并正式导出") |> render_click()

    queued = Repo.get_by!(RenderManifest, project_id: project.id, render_mode: :formal)
    assert queued.status == :prepared

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :media, with_safety: false)

    rendered = Repo.get!(RenderManifest, queued.id)
    assert rendered.status == :rendered
    assert rendered.output_asset_id
    assert rendered.srt_asset_id
  end

  defp upload_text(view, name, content) do
    upload =
      file_input(view, "#source-upload-form", :source, [
        %{name: name, content: content, type: "text/plain"}
      ])

    render_upload(upload, name)
    view |> form("#source-upload-form") |> render_submit()
  end

  defp drain_generation_pipeline do
    Oban.drain_queue(queue: :generation, with_safety: false)
    Oban.drain_queue(queue: :generation, with_safety: false)
    Oban.drain_queue(queue: :qc, with_safety: false)
    :ok
  end

  defp reference_assignments(project_id, asset_id) do
    visual_revision =
      Repo.one!(
        from revision in Dramatizer.Revisions.Revision,
          where: revision.project_id == ^project_id and revision.kind == :visual_design,
          order_by: [desc: revision.inserted_at],
          limit: 1
      )

    for object <- visual_revision.payload["objects"],
        object["reference_required"],
        variant <- object["variants"],
        slot <- variant["required_slots"],
        into: %{} do
      {"#{object["id"]}/#{variant["id"]}/#{slot}", asset_id}
    end
  end
end
