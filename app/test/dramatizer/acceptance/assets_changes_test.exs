defmodule Dramatizer.Acceptance.AssetsChangesTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Changes
  alias Dramatizer.Changes.StaleRecord
  alias Dramatizer.Generation
  alias Dramatizer.Generation.ImagePromptCompiler
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Visuals.ReferenceWorkflow

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-at-assets-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "AT-006 上传与提示词编辑共用 finalize 且父资产不可变" do
    assert {:ok, project} = Projects.create_project(%{name: "AT-006 图像编辑"})
    path = fake_png("parent")
    assert {:ok, parent} = ReferenceWorkflow.upload(project, path, purpose: "acceptance-upload")
    parent_hash = parent.blob_hash

    assert {:ok, compilation} =
             ImagePromptCompiler.compile(:image_edit, %{"instruction" => "加强雨夜反光"},
               reference_asset_ids: [parent.id]
             )

    assert {:ok, prepared} =
             ReferenceWorkflow.prepare_edit(project, parent, compilation, formal: false)

    assert {:ok, generated} =
             Dramatizer.Media.Worker.run(:generate_fake_image, %{
               "width" => 270,
               "height" => 480,
               "seed" => "child"
             })

    assert {:ok, child} =
             ReferenceWorkflow.finalize_result(project, prepared, %{
               bytes: Base.decode64!(generated["png_base64"]),
               mime_type: "image/png"
             })

    assert child.parent_asset_id == parent.id
    assert child.lineage["parent_asset_id"] == parent.id
    assert child.blob_hash != parent.blob_hash
    assert Assets.get_asset!(parent.id).blob_hash == parent_hash
  end

  test "AT-007 ChangeSet 仅处理精确依赖、标 stale 且不自动生成图像" do
    assert {:ok, project} = Projects.create_project(%{name: "AT-007 变更"})
    old = confirmed(project, :visual_design, %{"version" => 1})
    new = confirmed(project, :visual_design, %{"version" => 2})

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{"shot_id" => "S001"}
             })

    {asset, selection} = selected(project, spec)

    :ok = Changes.add_dependency(project, {"revision", old.id}, {"generation_spec", spec.id})

    :ok =
      Changes.add_dependency(project, {"generation_spec", spec.id}, {"asset_version", asset.id})

    :ok =
      Changes.add_dependency(
        project,
        {"asset_version", asset.id},
        {"selection_decision", selection.id}
      )

    assert {:ok, impact} = Changes.preview(project, old, new)

    assert Enum.map(impact.targets, & &1.id) |> MapSet.new() ==
             MapSet.new([spec.id, asset.id, selection.id])

    assert {:ok, change_set} = Changes.confirm(impact, :all)
    assert {:ok, completed} = Changes.resume(change_set)
    assert completed.status == :succeeded
    assert Repo.get_by!(StaleRecord, subject_type: "selection_decision", subject_id: selection.id)

    refute Repo.exists?(from job in Oban.Job, where: job.queue == "generation")
  end

  defp selected(project, spec) do
    path = fake_png("selection")
    assert {:ok, asset} = ReferenceWorkflow.upload(project, path, purpose: "at-selection")
    assert {:ok, _technical} = Quality.run_technical(asset, spec)
    assert {:ok, selection} = Quality.select(project, "shot:S001", spec, asset)
    {asset, selection}
  end

  defp confirmed(project, kind, payload) do
    assert {:ok, draft} = Revisions.create_draft(project, kind, payload, %{})
    assert {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  defp fake_png(seed) do
    assert {:ok, generated} =
             Dramatizer.Media.Worker.run(:generate_fake_image, %{
               "width" => 270,
               "height" => 480,
               "seed" => seed
             })

    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{seed}.png")
    File.write!(path, Base.decode64!(generated["png_base64"]))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
