defmodule Dramatizer.TimelineTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Changes
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.Clip

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-timeline-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "Timeline 编辑"})
    narrative = Fixture.confirmed(project, :narrative, Fixture.narrative_payload())
    shot_plan = Fixture.confirmed(project, :shot_plan, Fixture.shot_plan_payload())
    {_spec1, _asset1, selection1} = Fixture.selected_image(project, "S001", "shot:S001")
    {_spec3, _asset3, selection3} = Fixture.selected_image(project, "S003", "shot:S003")

    assert {:ok, timeline} =
             Timeline.create(project, narrative, shot_plan, %{
               "S001" => selection1,
               "S003" => selection3
             })

    %{
      project: project,
      narrative: narrative,
      shot_plan: shot_plan,
      timeline: timeline,
      selection1: selection1,
      selection3: selection3
    }
  end

  test "assembles ShotPlan order, placeholders, editable clips, durations, motion, and transitions",
       context do
    clips = Timeline.list_clips(context.timeline)
    assert Enum.map(clips, & &1.shot_id) == ~w(S001 S002 S003)
    assert Enum.map(clips, & &1.placeholder) == [false, true, false]
    assert Enum.map(clips, & &1.motion) == [:push_in, :pan_left, :static]
    assert Enum.all?(clips, &(&1.transition_after == :hard_cut))

    [first, second, third] = clips
    assert {:ok, snapped} = Timeline.set_duration(first, 1_960, snap: true)
    assert snapped.duration_ms == 2_000
    refute snapped.duration_warning

    assert {:ok, outside} = Timeline.set_duration(snapped, 3_500)
    assert outside.duration_ms == 3_500
    assert outside.duration_warning

    for motion <- [:static, :push_in, :pull_out, :pan_left, :pan_right, :pan_up, :pan_down] do
      assert {:ok, %Clip{motion: ^motion}} = Timeline.set_motion(second, motion)
    end

    assert {:ok, dissolve} = Timeline.set_transition(first, :cross_dissolve, 600)
    assert dissolve.transition_duration_ms == 600

    assert {:error, :transition_duration_out_of_bounds} =
             Timeline.set_transition(first, :cross_dissolve, 1_200)

    assert {:ok, moved} = Timeline.move_clip(context.timeline, third.id, 1)
    assert Enum.map(Timeline.list_clips(moved), & &1.shot_id) == ~w(S003 S001 S002)

    assert {:ok, added} =
             Timeline.add_clip(context.timeline, %{
               shot_id: "S004",
               position: 4,
               duration_ms: 1_000,
               motion: :static
             })

    assert length(Timeline.list_clips(context.timeline)) == 4
    assert {:ok, _timeline} = Timeline.remove_clip(context.timeline, added)
    assert length(Timeline.list_clips(context.timeline)) == 3

    assert {:ok, replaced} = Timeline.replace_clip(second, context.selection1)
    refute replaced.placeholder
    assert replaced.asset_version_id == context.selection1.asset_version_id

    reference_selection = %{context.selection1 | slot_key: "reference:character:linxia/front"}
    assert {:error, :shot_selection_required} = Timeline.replace_clip(second, reference_selection)
  end

  test "sentence subtitles are editable without mutating Narrative and freeze exact source/style",
       context do
    cues = Timeline.list_subtitles(context.timeline)
    assert Enum.map(cues, & &1.text) == ["你终于来了。", "雨还没有停？", "这封信不是我写的。"]
    [first | _] = cues
    original_narrative_hash = context.narrative.content_hash

    assert {:ok, edited} =
             Timeline.update_subtitle(first, %{
               text: "你总算来了。",
               start_ms: 120,
               end_ms: 980,
               style: %{"position" => "safe_bottom", "emphasis" => true}
             })

    assert edited.text == "你总算来了。"
    assert Revisions.get_revision!(context.narrative.id).content_hash == original_narrative_hash

    assert {:ok, version} = Timeline.freeze(context.timeline)
    frozen = Enum.find(version.subtitle_snapshot, &(&1["id"] == edited.id))
    assert frozen["text"] == "你总算来了。"
    assert frozen["start_ms"] == 120
    assert frozen["style"]["emphasis"] == true
    assert frozen["narrative_revision_id"] == context.narrative.id
    assert frozen["source_event_id"] == "D001"
  end

  test "exploratory selections remain placeholders in a formal timeline", context do
    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => 540,
        "height" => 960,
        "seed" => "exploratory"
      })

    {:ok, intent} =
      Dramatizer.Assets.create_upload_intent(context.project, %{
        purpose: "exploratory-shot",
        expected_mime: "image/png",
        idempotency_key: "timeline-exploratory"
      })

    {:ok, staged} =
      Dramatizer.Assets.stage_bytes(intent, Base.decode64!(generated["png_base64"]))

    {:ok, spec} =
      Dramatizer.Generation.create_spec(context.project, %{
        kind: "shot_keyframe",
        formal: false,
        payload: %{"shot_id" => "S002", "aspect_width" => 9, "aspect_height" => 16}
      })

    {:ok, asset} =
      Dramatizer.Assets.finalize(staged, %{
        "origin" => "fixture",
        "formal" => false,
        "generation_spec_id" => spec.id
      })

    {:ok, _technical} = Dramatizer.Quality.run_technical(asset, spec)
    {:ok, selection} = Dramatizer.Quality.select(context.project, "shot:S002", spec, asset)

    assert {:ok, timeline} =
             Timeline.create(context.project, context.narrative, context.shot_plan, %{
               "S002" => selection
             })

    exploratory_clip = Enum.find(Timeline.list_clips(timeline), &(&1.shot_id == "S002"))
    assert exploratory_clip.placeholder
    assert exploratory_clip.asset_version_id == nil
    assert exploratory_clip.selection_decision_id == nil
  end

  test "unresolved stale blocks formal freeze but preview remains available; pin-old unblocks",
       context do
    assert {:ok, _jobs} =
             Changes.schedule_neighbor_qc(
               context.project,
               ["shot:S001", "shot:S002", "shot:S003"],
               "shot:S001"
             )

    assert {:ok, preview} = Timeline.create_preview_manifest(context.timeline)
    assert preview.render_mode == :preview
    assert {:error, {:unresolved_stale, ids}} = Timeline.freeze(context.timeline)
    assert context.selection1.id in ids

    assert {:ok, _pinned} = Changes.resolve_stale(context.selection1, :pin_old_input)
    assert {:ok, version} = Timeline.freeze(context.timeline)
    assert version.timeline_id == context.timeline.id

    assert_raise Postgrex.Error, ~r/immutable_record/, fn ->
      Repo.delete!(version)
    end
  end
end
