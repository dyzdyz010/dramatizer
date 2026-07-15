defmodule Dramatizer.Timeline.RenderRecipeTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Projects
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.{RenderRecipe, SRT}

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
end
