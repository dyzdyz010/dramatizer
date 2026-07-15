defmodule Dramatizer.RevisionsTest do
  use Dramatizer.DataCase, async: true

  import Ecto.Query

  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.Revision

  test "AI payload remains a draft until confirmation creates one immutable revision" do
    assert {:ok, project} = Projects.create_project(%{name: "版本测试"})

    assert {:ok, draft} =
             Revisions.create_draft(
               project,
               :narrative,
               %{"title" => "第一集", "dialogue" => ["你好"]},
               %{"origin" => "fake_ai"}
             )

    assert draft.status == :editing
    assert {:ok, edited} = Revisions.update_draft(draft, %{"title" => "第一集：归来"})

    assert {:ok, revision} = Revisions.confirm_draft(edited.id)
    assert revision.kind == :narrative
    assert revision.revision == 1
    assert revision.payload["title"] == "第一集：归来"
    assert byte_size(revision.content_hash) == 64

    assert {:ok, same_revision} = Revisions.confirm_draft(edited.id)
    assert same_revision.id == revision.id
    assert {:error, :draft_confirmed} = Revisions.update_draft(edited, %{"title" => "不能覆盖"})

    assert {:ok, derived} = Revisions.derive_draft(revision.id)
    assert derived.base_revision_id == revision.id
    assert derived.logical_id == revision.logical_id
    assert {:ok, next_revision} = Revisions.confirm_draft(derived.id)
    assert next_revision.revision == 2
    assert next_revision.parent_revision_id == revision.id
  end

  test "confirmed revisions reject SQL update and delete operations" do
    assert {:ok, project} = Projects.create_project(%{name: "不可变测试"})
    assert {:ok, draft} = Revisions.create_draft(project, :narrative, %{"title" => "原值"}, %{})
    assert {:ok, revision} = Revisions.confirm_draft(draft.id)

    assert_raise Postgrex.Error, ~r/immutable_record/, fn ->
      Repo.update_all(
        from(item in Revision, where: item.id == ^revision.id),
        set: [payload: %{"title" => "覆盖"}]
      )
    end
  end

  test "a narrative episode override is frozen into its revision profile snapshot" do
    assert {:ok, project} = Projects.create_project(%{name: "单集规格覆盖"})

    assert {:ok, draft} =
             Revisions.create_draft(
               project,
               :narrative,
               %{
                 "title" => "加长集",
                 "production_profile_override" => %{
                   "duration_min_seconds" => 90,
                   "duration_max_seconds" => 150,
                   "shot_max" => 36
                 }
               },
               %{}
             )

    assert {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision = Repo.get!(Revision, revision.id)
    assert revision.profile_snapshot["duration_min_seconds"] == 90
    assert revision.profile_snapshot["duration_max_seconds"] == 150
    assert revision.profile_snapshot["shot_max"] == 36
    assert Projects.effective_profile(project).duration_min_seconds == 60
  end

  test "replace_draft_payload replaces instead of merging and rejects stale writers" do
    assert {:ok, project} = Projects.create_project(%{name: "完整表单保存"})

    assert {:ok, draft} =
             Revisions.create_draft(
               project,
               :narrative,
               %{"title" => "旧标题", "removed_by_form" => true},
               %{}
             )

    assert {:ok, replaced} =
             Revisions.replace_draft_payload(draft, %{
               "schema_version" => "narrative-draft-v2",
               "title" => "新标题"
             })

    refute Map.has_key?(replaced.payload, "removed_by_form")
    assert replaced.payload["title"] == "新标题"

    assert {:error, :stale_draft} =
             Revisions.replace_draft_payload(draft, %{"title" => "过期覆盖"})
  end
end
