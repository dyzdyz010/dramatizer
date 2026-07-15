defmodule Dramatizer.Generation.ImagePromptProposalTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation.ImagePromptProposal
  alias Dramatizer.Projects
  alias Dramatizer.Repo

  test "AI refines an image prompt through a persisted idempotent text attempt" do
    assert {:ok, project} = Projects.create_project(%{name: "AI 图像提示词"})
    assert {:ok, _budget} = Costs.set_budget(project, 100)

    assert {:ok, appendix} =
             Projects.create_prompt_appendix(project, :image_prompt, "画面细节要适合中国竖屏短剧。")

    test_pid = self()

    submitter = fn snapshot, _attempt ->
      send(test_pid, {:submitted, snapshot.id})
      assert Costs.get_budget(project).reserved_micros == 40
      assert snapshot.task_type == "image_prompt"
      assert snapshot.model == "gpt-5.6-terra"
      assert snapshot.request_input["schema_name"] == "image_prompt_proposal"
      assert snapshot.request_input["input"] =~ "林夏"
      assert snapshot.request_input["input"] =~ appendix.body

      {:ok,
       %{
         output: %{
           "provider_prompt" => "27岁中国女性林夏，黑色短发，雨夜旧车站，湿润反光，电影级竖屏构图"
         },
         external_request_id: "prompt-1",
         request_id: "req-prompt-1",
         usage: %{"total_tokens" => 33}
       }}
    end

    authority = %{
      "角色" => %{"姓名" => "林夏", "年龄" => 27, "发型" => "黑色短发"},
      "场景" => "雨夜旧车站",
      "必须项" => ["匿名信"],
      "禁止项" => ["现代广告牌"]
    }

    opts = [
      provider_mode: :openai,
      submitter: submitter,
      task_override: %{params: %{"estimated_cost_micros" => 40}}
    ]

    assert {:ok, first} =
             ImagePromptProposal.propose(project, :shot_keyframe, authority, opts)

    assert first.provider_prompt =~ "湿润反光"
    assert first.request_snapshot.prompt_snapshot["appendix_revision_id"] == appendix.id
    assert first.attempt.status == :succeeded
    assert_receive {:submitted, snapshot_id}
    assert snapshot_id == first.request_snapshot.id
    assert Costs.get_budget(project).reserved_micros == 0

    assert {:ok, replayed} =
             ImagePromptProposal.propose(project, :shot_keyframe, authority, opts)

    assert replayed.request_snapshot.id == first.request_snapshot.id
    assert replayed.attempt.id == first.attempt.id
    refute_receive {:submitted, _snapshot_id}, 50

    entries = Repo.all(from entry in CostEntry, where: entry.project_id == ^project.id)
    assert Enum.count(entries, &(&1.entry_type == :estimate)) == 1
    assert Enum.count(entries, &(&1.entry_type == :reservation)) == 1
    assert Enum.count(entries, &(&1.entry_type == :actual)) == 1
    assert Enum.find(entries, &(&1.entry_type == :actual)).amount_micros == nil
  end
end
