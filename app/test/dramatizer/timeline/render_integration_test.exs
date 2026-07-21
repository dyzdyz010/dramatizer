defmodule Dramatizer.Timeline.RenderIntegrationTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.Jobs.RenderJob
  alias Dramatizer.Timeline.{RenderManifest, RenderRecipe}

  @tag timeout: 180_000
  test "formal FFmpeg export is H.264 portrait video with AAC stereo silence and exact SRT",
       _context do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)
    root = Path.join(System.tmp_dir!(), "dramatizer-render-#{System.unique_integer([:positive])}")
    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "FFmpeg 正式导出"})

    narrative =
      Fixture.confirmed(project, :narrative, %{
        "dialogue_events" => [
          %{
            "id" => "D001",
            "shot_id" => "S001",
            "text" => "雨夜。",
            "start_ms" => 50,
            "end_ms" => 700,
            "style" => %{"position" => "safe_bottom"}
          }
        ]
      })

    shot_plan =
      Fixture.confirmed(project, :shot_plan, %{
        "shots" => [
          %{
            "id" => "S001",
            "minimum_duration_ms" => 700,
            "preferred_duration_ms" => 800,
            "maximum_duration_ms" => 1000,
            "camera" => "static"
          },
          %{
            "id" => "S002",
            "minimum_duration_ms" => 700,
            "preferred_duration_ms" => 800,
            "maximum_duration_ms" => 1000,
            "camera" => "push_in"
          }
        ],
        "audio_strategy" => "silence_placeholder"
      })

    {_spec1, _asset1, selection1} = Fixture.selected_image(project, "S001", "shot:S001", 270, 480)
    {_spec2, _asset2, selection2} = Fixture.selected_image(project, "S002", "shot:S002", 270, 480)

    assert {:ok, timeline} =
             Timeline.create(project, narrative, shot_plan, %{
               "S001" => selection1,
               "S002" => selection2
             })

    assert {:ok, version} = Timeline.freeze(timeline)
    assert {:ok, manifest} = RenderRecipe.formal(version)
    assert {:ok, %{node_run: node, job: job}} = Timeline.enqueue_render(manifest)
    assert Repo.get!(RenderManifest, manifest.id).status == :prepared
    assert job.args == %{"node_run_id" => node.id}

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(queue: :media, with_safety: false)

    rendered = Repo.get!(RenderManifest, manifest.id)

    assert rendered.status == :rendered
    mp4 = Assets.get_asset!(rendered.output_asset_id)
    srt = Assets.get_asset!(rendered.srt_asset_id)
    assert mp4.mime_type == "video/mp4"
    assert mp4.lineage["formal"] == true
    assert srt.mime_type == "application/x-subrip"
    assert File.read!(Assets.absolute_path(srt)) =~ "雨夜。"

    probe = rendered.technical_qc
    assert probe["status"] == "pass"
    assert probe["video_codec"] == "h264"
    assert probe["pixel_format"] == "yuv420p"
    assert probe["width"] == 1080
    assert probe["height"] == 1920
    assert probe["audio_codec"] == "aac"
    assert probe["audio_channels"] == 2
    assert probe["audio_is_silence"] == true
    assert abs(probe["duration_ms"] - version.duration_ms) <= 150
    assert rendered.input_manifest["subtitle_burn_in"] == true

    output_asset_id = rendered.output_asset_id
    srt_asset_id = rendered.srt_asset_id

    assert {:ok, %{node_run: same_node, job: same_job}} = Timeline.enqueue_render(rendered)
    assert same_node.id == node.id
    assert same_job.id == job.id

    assert :ok = RenderJob.perform(job)
    replayed = Repo.get!(RenderManifest, manifest.id)
    assert replayed.output_asset_id == output_asset_id
    assert replayed.srt_asset_id == srt_asset_id
  end
end
