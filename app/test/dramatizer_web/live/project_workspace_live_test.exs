defmodule DramatizerWeb.ProjectWorkspaceLiveTest do
  use DramatizerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.Projects
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Revisions.Draft
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline.{Clip, RenderManifest, SubtitleCue, Timeline}
  alias Dramatizer.Workflow.InboxMessage
  alias Dramatizer.Repo

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

  test "state vocabulary covers empty/loading/failed/ready/waiting-user/stale", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/projects/#{project.id}/runs")

    for state <- ~w(empty loading failed ready waiting_user stale) do
      assert has_element?(view, "#state-legend [data-state='#{state}']")
    end
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

  test "direct LiveView text upload is parsed, automatically analyzed, and routed to review", %{
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
    assert Repo.get_by!(AnalysisSnapshot, project_id: project.id)
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

    {:ok, analysis, _html} = live(conn, "/projects/#{project.id}/analysis")
    assert has_element?(analysis, "[data-stage='analysis'][data-state='ready']")
    assert has_element?(analysis, ".dag-node [data-state='ready']")
    assert has_element?(analysis, "[data-analysis-review]")
    assert render(analysis) =~ "人物与关系"
    assert render(analysis) =~ "地点、道具与世界"

    {:ok, episodes, html} = live(conn, "/projects/#{project.id}/episodes")
    assert html =~ "雨夜来信"
    assert has_element?(episodes, "button[phx-click='select-episode']")

    episodes |> element("button[phx-click='select-episode']") |> render_click()
    html = render(episodes)
    assert html =~ "分集概览"
    assert html =~ "Scene"
    assert has_element?(episodes, "form[phx-submit='save-narrative-draft']")
    refute html =~ "结构化内容"
    refute has_element?(episodes, "textarea[name='draft[payload]']")

    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

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
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.one!(from attempt in Attempt, select: attempt.status) == :failed

    runs |> element("button", "恢复并注入重复乱序回调") |> render_click()
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(AssetVersion, :count) == 1
    assert Repo.aggregate(InboxMessage, :count) == 1
    assert Repo.aggregate(from(cost in CostEntry, where: cost.entry_type == :actual), :count) == 1

    runs |> element("button", "恢复并注入重复乱序回调") |> render_click()
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(AssetVersion, :count) == 1
    assert Repo.aggregate(from(cost in CostEntry, where: cost.entry_type == :actual), :count) == 1
  end

  @tag timeout: 180_000
  test "visual workspace generates reference candidates, records explicit choices, and edits immutably",
       %{conn: conn, project: project} do
    {:ok, source, _html} = live(conn, "/projects/#{project.id}/source")
    upload_text(source, "reference-story.txt", "林夏在雨夜车站打开一封匿名信。")

    {:ok, analysis, _html} = live(conn, "/projects/#{project.id}/analysis")
    analysis |> element("button", "启动全文分析") |> render_click()

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    episodes |> element("button[phx-click='select-episode']") |> render_click()
    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

    {:ok, visuals, _html} = live(conn, "/projects/#{project.id}/visuals")

    visual = Repo.get_by!(Draft, project_id: project.id, kind: :visual_design, status: :editing)
    visuals |> element("button[phx-value-id='#{visual.id}']", "确认并冻结") |> render_click()
    visuals |> element("button", "AI 生成参考候选") |> render_click()

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

    for slot <- required_slots do
      visuals
      |> element(
        "button[phx-click='select-candidate'][phx-value-slot-key='reference:#{slot}'][data-candidate-index='0']",
        "选择此候选"
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
    analysis |> element("button", "启动全文分析") |> render_click()

    {:ok, episodes, _html} = live(conn, "/projects/#{project.id}/episodes")
    episodes |> element("button[phx-click='select-episode']") |> render_click()
    narrative = Repo.get_by!(Draft, project_id: project.id, kind: :narrative, status: :editing)
    episodes |> element("button[phx-value-id='#{narrative.id}']", "确认并冻结") |> render_click()

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

    {:ok, shots, _html} = live(conn, "/projects/#{project.id}/shots")
    shots |> form("form[phx-submit='create-shot-plan']") |> render_submit()
    shot_plan = Repo.get_by!(Draft, project_id: project.id, kind: :shot_plan, status: :editing)
    shots |> element("button[phx-value-id='#{shot_plan.id}']", "确认并冻结") |> render_click()
    shots |> element("button", "编译冻结 GenerationSpec") |> render_click()
    shots |> element("button", "生成候选并执行 QC") |> render_click()
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

    rendered = Repo.get_by!(RenderManifest, project_id: project.id, render_mode: :formal)
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
