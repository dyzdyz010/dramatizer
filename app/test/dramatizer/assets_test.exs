defmodule Dramatizer.AssetsTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Assets.{AssetVersion, UploadIntent}
  alias Dramatizer.Projects
  alias Dramatizer.Repo

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-assets-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "an asset becomes visible only after successful finalize" do
    assert {:ok, project} = Projects.create_project(%{name: "资产测试"})

    assert {:ok, intent} =
             Assets.create_upload_intent(project, %{
               purpose: "reference_image",
               expected_mime: "image/png",
               idempotency_key: "asset-visible-on-finalize"
             })

    assert Repo.aggregate(AssetVersion, :count) == 0
    assert {:ok, staged} = Assets.stage_bytes(intent, @png)
    assert staged.status == :staging
    assert Repo.aggregate(AssetVersion, :count) == 0

    assert {:ok, asset} = Assets.finalize(staged, %{"origin" => "upload"})
    assert asset.blob_hash == :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)
    assert asset.relative_path =~ ~r|^final/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}$|
    assert File.read!(Assets.absolute_path(asset)) == @png
    assert Assets.verify(asset) == :ok

    finalized = Repo.get!(UploadIntent, intent.id)
    assert finalized.status == :finalized
    assert finalized.finalized_asset_id == asset.id
  end

  test "identical bytes deduplicate the blob while retaining distinct lineage records" do
    assert {:ok, project} = Projects.create_project(%{name: "去重测试"})

    assets =
      for index <- 1..2 do
        assert {:ok, intent} =
                 Assets.create_upload_intent(project, %{
                   purpose: "shot_keyframe",
                   expected_mime: "image/png",
                   idempotency_key: "dedupe-#{index}"
                 })

        assert {:ok, staged} = Assets.stage_bytes(intent, @png)
        assert {:ok, asset} = Assets.finalize(staged, %{"candidate_index" => index})
        asset
      end

    [first, second] = assets
    assert first.id != second.id
    assert first.blob_hash == second.blob_hash
    assert first.relative_path == second.relative_path
    assert first.lineage["candidate_index"] == 1
    assert second.lineage["candidate_index"] == 2
  end

  test "invalid staged media is recoverable and child assets never overwrite parents" do
    assert {:ok, project} = Projects.create_project(%{name: "恢复测试"})

    assert {:ok, parent_intent} =
             Assets.create_upload_intent(project, %{
               purpose: "reference_image",
               expected_mime: "image/png",
               idempotency_key: "parent"
             })

    assert {:ok, staged_parent} = Assets.stage_bytes(parent_intent, @png)
    assert {:ok, parent} = Assets.finalize(staged_parent)
    parent_hash = parent.blob_hash

    assert {:ok, child_intent} =
             Assets.create_upload_intent(project, %{
               purpose: "image_edit",
               expected_mime: "image/png",
               idempotency_key: "child"
             })

    assert {:ok, bad_stage} = Assets.stage_bytes(child_intent, "not an image")
    assert {:error, :invalid_image} = Assets.finalize(bad_stage, %{parent_asset_id: parent.id})
    assert Repo.get!(UploadIntent, child_intent.id).status == :failed

    assert {:ok, recovered_stage} = Assets.stage_bytes(child_intent, @png)
    assert {:ok, child} = Assets.finalize(recovered_stage, %{parent_asset_id: parent.id})
    assert child.parent_asset_id == parent.id
    assert Repo.get!(AssetVersion, parent.id).blob_hash == parent_hash

    assert {:ok, same_child} = Assets.finalize(recovered_stage, %{parent_asset_id: parent.id})
    assert same_child.id == child.id
  end
end
