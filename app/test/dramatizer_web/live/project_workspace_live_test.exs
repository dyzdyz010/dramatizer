defmodule DramatizerWeb.ProjectWorkspaceLiveTest do
  use DramatizerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Dramatizer.Projects
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Revisions.Draft
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline.{RenderManifest, Timeline}
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

  test "direct LiveView text upload is consumed into the source parser", %{
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

    assert render(view) =~ "novel.txt"
    assert render(view) =~ "已解析全文"
    assert Repo.get_by!(SourceRevision, project_id: project.id).character_count > 0
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

  test "fake full-text analysis completes the persisted DAG and exposes episode candidates", %{
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
    analysis |> element("button", "启动全文分析") |> render_click()
    assert has_element?(analysis, "[data-stage='analysis'][data-state='ready']")
    assert has_element?(analysis, ".dag-node [data-state='ready']")

    {:ok, episodes, html} = live(conn, "/projects/#{project.id}/episodes")
    assert html =~ "雨夜来信"
    assert has_element?(episodes, "button[phx-click='select-episode']")
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
    visuals |> form("form[phx-submit='create-visual-design']") |> render_submit()
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
    assert Repo.get_by!(Timeline, project_id: project.id)
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
