defmodule Dramatizer.Acceptance.TimelineRestoreTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Backup
  alias Dramatizer.Changes
  alias Dramatizer.Projects
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.RenderRecipe

  test "AT-008 AT-009 AT-010 stale 门、媒体配方与恢复闭包" do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    source_root =
      Path.join(System.tmp_dir!(), "dramatizer-at-timeline-#{System.unique_integer([:positive])}")

    restore_root = source_root <> "-restore"
    Application.put_env(:dramatizer, :asset_store_root, source_root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(source_root)
      File.rm_rf!(restore_root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "AT-008-010"})
    narrative = Fixture.confirmed(project, :narrative, Fixture.narrative_payload())
    shot_plan = Fixture.confirmed(project, :shot_plan, Fixture.shot_plan_payload())
    {_spec, _asset, selection} = Fixture.selected_image(project, "S001", "shot:S001")

    assert {:ok, timeline} =
             Timeline.create(project, narrative, shot_plan, %{"S001" => selection})

    assert {:ok, _jobs} = Changes.schedule_neighbor_qc(project, ["shot:S001"], "shot:S001")
    assert {:ok, preview} = RenderRecipe.preview(timeline)
    assert preview.render_mode == :preview
    assert {:error, {:unresolved_stale, [selection_id]}} = Timeline.freeze(timeline)
    assert selection_id == selection.id
    assert {:ok, _pinned} = Changes.resolve_stale(selection, :pin_old_input)

    assert {:ok, version} = Timeline.freeze(timeline)
    assert {:ok, formal} = RenderRecipe.formal(version)
    assert formal.width == 1080
    assert formal.height == 1920
    manifest = Backup.manifest()
    assert :ok = Backup.copy_asset_store(source_root, restore_root)
    Application.put_env(:dramatizer, :asset_store_root, restore_root)
    assert Backup.verify_manifest(manifest)["status"] == "ok"
    assert {:ok, same} = RenderRecipe.formal(version)
    assert same.recipe_hash == formal.recipe_hash
    assert same.input_manifest == formal.input_manifest
  end
end
