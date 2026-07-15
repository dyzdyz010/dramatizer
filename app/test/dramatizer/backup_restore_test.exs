defmodule Dramatizer.BackupRestoreTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Backup
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.TestFixtures.Timeline, as: Fixture
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.{RenderManifest, RenderRecipe}

  test "restored AssetStore verifies and regenerates the same normalized formal recipe" do
    original_root = Application.fetch_env!(:dramatizer, :asset_store_root)

    source_root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-backup-source-#{System.unique_integer([:positive])}"
      )

    restore_root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-backup-restore-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, source_root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, original_root)
      File.rm_rf!(source_root)
      File.rm_rf!(restore_root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "恢复配方"})
    narrative = Fixture.confirmed(project, :narrative, Fixture.narrative_payload())
    shot_plan = Fixture.confirmed(project, :shot_plan, Fixture.shot_plan_payload())
    {_spec, _asset, selection} = Fixture.selected_image(project, "S001", "shot:S001")

    assert {:ok, timeline} =
             Timeline.create(project, narrative, shot_plan, %{"S001" => selection})

    assert {:ok, version} = Timeline.freeze(timeline)
    assert {:ok, before} = RenderRecipe.formal(version)
    manifest = Backup.manifest()

    assert :ok = Backup.copy_asset_store(source_root, restore_root)
    Application.put_env(:dramatizer, :asset_store_root, restore_root)
    assert Backup.verify_assets()["status"] == "ok"
    assert Backup.verify_manifest(manifest)["status"] == "ok"

    Repo.delete!(before)
    assert {:ok, regenerated} = RenderRecipe.formal(version)
    assert regenerated.recipe_hash == before.recipe_hash
    assert regenerated.input_manifest == before.input_manifest
    assert regenerated.timeline_version_id == version.id
    assert Repo.get!(RenderManifest, regenerated.id)
  end
end
