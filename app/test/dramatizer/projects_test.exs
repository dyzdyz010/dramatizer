defmodule Dramatizer.ProjectsTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Projects

  test "projects are independent and may be renamed or archived" do
    assert {:ok, first} = Projects.create_project(%{name: "长夜"})
    assert {:ok, second} = Projects.create_project(%{name: "归途"})
    assert first.id != second.id
    assert first.status == :active

    assert {:ok, renamed} = Projects.rename_project(first, "长夜改编")
    assert renamed.name == "长夜改编"

    assert {:ok, archived} = Projects.archive_project(second)
    assert archived.status == :archived
  end

  test "production profile resolves system, project, then episode values" do
    assert {:ok, project} = Projects.create_project(%{name: "山海"})

    profile = Projects.effective_profile(project)
    assert profile.aspect_width == 9
    assert profile.aspect_height == 16
    assert profile.duration_min_seconds == 60
    assert profile.duration_max_seconds == 120
    assert profile.shot_min == 10
    assert profile.shot_max == 30

    assert {:ok, _profile} =
             Projects.update_production_profile(project, %{
               duration_min_seconds: 75,
               shot_max: 24
             })

    effective = Projects.effective_profile(project, %{duration_min_seconds: 90})
    assert effective.duration_min_seconds == 90
    assert effective.shot_max == 24
    assert effective.formal_width == 1080
    assert effective.formal_height == 1920
  end

  test "prompt appendix revisions are append-only per task" do
    assert {:ok, project} = Projects.create_project(%{name: "灯塔"})

    assert {:ok, first} =
             Projects.create_prompt_appendix(project, :people_relations, "强调人物别名。")

    assert {:ok, second} =
             Projects.create_prompt_appendix(project, :people_relations, "注意亲属关系。")

    assert first.revision == 1
    assert second.revision == 2
    assert first.body_hash != second.body_hash
    assert Projects.current_prompt_appendix(project, :people_relations).id == second.id
  end

  test "model overrides reject non-positive candidate counts" do
    assert {:ok, project} = Projects.create_project(%{name: "候选数边界"})

    assert {:error, changeset} =
             Projects.put_model_override(project, :reference_image, %{
               model: "gpt-image-2",
               params: %{"candidate_count" => 0}
             })

    assert "must be a positive integer" in errors_on(changeset).params
    refute Projects.model_override(project, :reference_image)
  end

  test "project model override can be removed to restore inheritance" do
    assert {:ok, project} = Projects.create_project(%{name: "恢复模型继承"})

    assert {:ok, _override} =
             Projects.put_model_override(project, :shot_keyframe, %{
               model: "gpt-image-2",
               params: %{"quality" => "high"}
             })

    assert Projects.model_override(project, :shot_keyframe)
    assert :ok = Projects.delete_model_override(project, :shot_keyframe)
    refute Projects.model_override(project, :shot_keyframe)
  end
end
