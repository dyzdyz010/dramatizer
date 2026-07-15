defmodule Dramatizer.Visuals.ReferenceWorkflowTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Generation.{ConfigResolver, ImagePromptCompiler}
  alias Dramatizer.Projects
  alias Dramatizer.Visuals.ReferenceWorkflow

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-reference-workflow-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "candidate counts resolve system then Project then one-shot and freeze in snapshots" do
    assert {:ok, project} = Projects.create_project(%{name: "候选数量"})
    compilation = prompt_compilation()

    assert ConfigResolver.resolve(:reference_image, project).params["candidate_count"] == 4
    assert ConfigResolver.resolve(:shot_keyframe, project).params["candidate_count"] == 2

    assert {:ok, system_prepared} =
             ReferenceWorkflow.prepare_candidates(project, :reference, compilation)

    assert length(system_prepared) == 4
    assert Enum.all?(system_prepared, &(&1.snapshot.params["candidate_count"] == 4))

    assert {:ok, _override} =
             Projects.put_model_override(project, :reference_image, %{
               params: %{"candidate_count" => 3}
             })

    assert {:ok, project_prepared} =
             ReferenceWorkflow.prepare_candidates(project, :reference, compilation)

    assert length(project_prepared) == 3

    assert {:ok, task_prepared} =
             ReferenceWorkflow.prepare_candidates(project, :reference, compilation,
               task_override: %{params: %{"candidate_count" => 1}}
             )

    assert length(task_prepared) == 1
    assert hd(task_prepared).snapshot.params["candidate_count"] == 1
  end

  test "controlled prompt preserves Chinese authority and exact links without mutating revisions" do
    authority = %{
      "角色" => "林夏，二十七岁，黑色短发",
      "场景" => "雨夜旧车站",
      "必须出现" => ["未署名信件"],
      "禁止出现" => ["现代广告牌"]
    }

    assert {:ok, compiled} =
             ImagePromptCompiler.compile(:shot_keyframe, authority,
               revision_ids: ["visual-r1", "shot-r1"],
               reference_asset_ids: ["asset-a"],
               user_instruction: "低机位，电影感"
             )

    assert authority == compiled.chinese_authority
    assert compiled.provider_prompt =~ "林夏，二十七岁"
    assert compiled.provider_prompt =~ "低机位，电影感"
    assert compiled.links["revision_ids"] == ["visual-r1", "shot-r1"]
    assert compiled.links["reference_asset_ids"] == ["asset-a"]
    assert byte_size(compiled.chinese_authority_hash) == 64
    assert compiled.compiler_version == "image-prompt-compiler-v1"
  end

  test "uploads and AI edits share finalize while child lineage and formal promotion remain immutable" do
    assert {:ok, project} = Projects.create_project(%{name: "编辑谱系"})
    source_path = temporary_png()

    assert {:ok, uploaded} =
             ReferenceWorkflow.upload(project, source_path, purpose: "reference_upload")

    parent_hash = uploaded.blob_hash
    compilation = prompt_compilation()

    assert {:ok, [exploratory]} =
             ReferenceWorkflow.prepare_candidates(project, :shot, compilation,
               formal: false,
               task_override: %{params: %{"candidate_count" => 1}}
             )

    assert {:ok, exploratory_asset} =
             ReferenceWorkflow.finalize_result(project, exploratory, %{
               bytes: @png,
               mime_type: "image/png"
             })

    refute ReferenceWorkflow.formal_timeline_eligible?(exploratory_asset)

    assert {:ok, edit} =
             ReferenceWorkflow.prepare_edit(project, uploaded, compilation,
               mask_asset: exploratory_asset,
               formal: false
             )

    edited_png = fake_png(2, 1)

    assert {:ok, child} =
             ReferenceWorkflow.finalize_result(project, edit, %{
               bytes: edited_png,
               mime_type: "image/png"
             })

    assert child.parent_asset_id == uploaded.id
    assert child.lineage["mask_asset_id"] == exploratory_asset.id
    assert child.lineage["formal"] == false
    assert Assets.get_asset!(uploaded.id).blob_hash == parent_hash
    refute child.blob_hash == parent_hash

    assert {:ok, promoted} = ReferenceWorkflow.promote(project, exploratory)
    assert promoted.spec.formal
    assert promoted.spec.id != exploratory.spec.id
    assert promoted.attempt.id != exploratory.attempt.id
    assert promoted.spec.payload["promoted_from_spec_id"] == exploratory.spec.id
  end

  defp prompt_compilation do
    {:ok, compiled} =
      ImagePromptCompiler.compile(:reference_image, %{"对象" => "林夏", "造型" => "黑色短发"},
        revision_ids: ["visual-r1"]
      )

    compiled
  end

  defp temporary_png do
    path =
      Path.join(System.tmp_dir!(), "dramatizer-upload-#{System.unique_integer([:positive])}.png")

    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp fake_png(width, height) do
    python = Application.fetch_env!(:dramatizer, :media_worker_python)

    code =
      "from PIL import Image; import io,sys; b=io.BytesIO(); Image.new('RGB',(#{width},#{height}),(2,3,4)).save(b,'PNG'); sys.stdout.buffer.write(b.getvalue())"

    {bytes, 0} = System.cmd(python, ["-c", code])
    bytes
  end
end
