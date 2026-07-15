defmodule Mix.Tasks.DramatizerAssetsVerifyTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Backup
  alias Dramatizer.Projects

  setup do
    previous_root = Application.fetch_env!(:dramatizer, :asset_store_root)
    previous_key = System.get_env("OPENAI_API_KEY")
    root = Path.join(System.tmp_dir!(), "dramatizer-verify-#{System.unique_integer([:positive])}")
    Application.put_env(:dramatizer, :asset_store_root, root)
    System.put_env("OPENAI_API_KEY", "must-never-enter-backup")

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous_root)
      restore_env("OPENAI_API_KEY", previous_key)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "资产校验"})

    assert {:ok, generated} =
             Dramatizer.Media.Worker.run(:generate_fake_image, %{
               "width" => 90,
               "height" => 160,
               "seed" => "verify"
             })

    assert {:ok, intent} =
             Assets.create_upload_intent(project, %{
               purpose: "backup-fixture",
               expected_mime: "image/png",
               idempotency_key: "backup-fixture"
             })

    assert {:ok, staged} = Assets.stage_bytes(intent, Base.decode64!(generated["png_base64"]))
    assert {:ok, asset} = Assets.finalize(staged, %{"origin" => "fixture"})
    %{root: root, asset: asset}
  end

  test "manifest contains immutable asset facts and effective non-secret config", context do
    manifest = Backup.manifest()
    entry = Enum.find(manifest["assets"], &(&1["id"] == context.asset.id))
    assert entry["blob_hash"] == context.asset.blob_hash
    assert entry["relative_path"] == context.asset.relative_path
    assert entry["byte_size"] == context.asset.byte_size
    assert manifest["config"]["provider_mode"] == "fake"
    assert manifest["config"]["model_defaults"]["shot_keyframe"]["model"]
    refute Jason.encode!(manifest) =~ "must-never-enter-backup"
    refute Jason.encode!(manifest) =~ "OPENAI_API_KEY="
    assert Backup.verify_assets()["status"] == "ok"
  end

  test "verification reports corrupt, missing, and orphan final blobs", context do
    asset_path = Assets.absolute_path(context.asset)
    original = File.read!(asset_path)

    File.write!(asset_path, "corrupt")
    corrupt = Backup.verify_assets()
    assert Enum.any?(corrupt["corrupt"], &(&1["id"] == context.asset.id))

    File.rm!(asset_path)
    missing = Backup.verify_assets()
    assert Enum.any?(missing["missing"], &(&1["id"] == context.asset.id))

    File.mkdir_p!(Path.dirname(asset_path))
    File.write!(asset_path, original)
    orphan = Path.join([context.root, "final", "ff", "ff", String.duplicate("f", 64)])
    File.mkdir_p!(Path.dirname(orphan))
    File.write!(orphan, "orphan")

    report = Backup.verify_assets()
    assert Enum.any?(report["orphan"], &String.ends_with?(&1, String.duplicate("f", 64)))
    assert report["status"] == "error"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
