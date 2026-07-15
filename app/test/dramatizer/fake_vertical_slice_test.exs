defmodule Dramatizer.FakeVerticalSliceTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation.{Attempt, Orchestrator}
  alias Dramatizer.Generation
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.{QualityReport, SelectionDecision}
  alias Dramatizer.Repo
  alias Dramatizer.TestFixtures.FakeEpisode
  alias Dramatizer.Workflow.InboxMessage

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-fake-slice-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "one episode, one scene, and three shots complete through QC and explicit selection" do
    assert {:ok, project} = Projects.create_project(%{name: "Fake 三镜头"})
    specs = FakeEpisode.build_specs(project)

    results =
      Enum.map(specs, fn spec ->
        assert {:ok, result} = Orchestrator.generate(spec, :shot_keyframe, project)
        result
      end)

    assert length(results) == 6
    assert Repo.aggregate(Attempt, :count) == 6
    assert Repo.aggregate(AssetVersion, :count) == 6
    assert Repo.aggregate(QualityReport, :count) == 12
    assert Repo.aggregate(SelectionDecision, :count) == 0

    results
    |> Enum.group_by(& &1.spec.payload["shot_id"])
    |> Enum.each(fn {shot_id, [chosen | _rest]} ->
      assert {:ok, decision} =
               Quality.select(project, "shot:#{shot_id}", chosen.spec, chosen.asset)

      assert decision.asset_version_id == chosen.asset.id
    end)

    assert Repo.aggregate(SelectionDecision, :count) == 3
    assert Enum.all?(results, &(&1.technical_qc.status == :pass))
    assert Enum.all?(results, &(&1.semantic_qc.status in [:pass, :warning]))
  end

  test "failure, timeout, and duplicate callback injection recover without duplicate cost" do
    assert {:ok, project} = Projects.create_project(%{name: "Fake 恢复"})

    assert {:ok, failure_spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               candidate_index: 0,
               payload: %{"shot_id" => "FAIL", "width" => 540, "height" => 960}
             })

    failure_profile = %{
      fail_on_attempt: 1,
      duplicate_callbacks: 2,
      out_of_order_callbacks: true,
      delay_ms: 1,
      cost_micros: 23
    }

    assert {:error, :provider_rejected} =
             Orchestrator.generate(failure_spec, :shot_keyframe, project,
               fault_profile: failure_profile
             )

    assert {:ok, recovered} =
             Orchestrator.generate(failure_spec, :shot_keyframe, project,
               fault_profile: failure_profile
             )

    assert recovered.attempt.attempt_number == 2

    assert {:ok, same_result} =
             Orchestrator.generate(failure_spec, :shot_keyframe, project,
               fault_profile: failure_profile
             )

    assert same_result.asset.id == recovered.asset.id
    assert Repo.aggregate(InboxMessage, :count) == 1

    actual_costs = Repo.all(from entry in CostEntry, where: entry.entry_type == :actual)
    assert Enum.map(actual_costs, & &1.amount_micros) == [23]

    assert {:ok, timeout_spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               candidate_index: 0,
               payload: %{"shot_id" => "TIMEOUT", "width" => 540, "height" => 960}
             })

    timeout_profile = %{timeout_on_attempt: 1, cost_micros: 5}

    assert {:error, :provider_timeout} =
             Orchestrator.generate(timeout_spec, :shot_keyframe, project,
               fault_profile: timeout_profile
             )

    assert {:ok, timeout_recovered} =
             Orchestrator.generate(timeout_spec, :shot_keyframe, project,
               fault_profile: timeout_profile
             )

    assert timeout_recovered.attempt.attempt_number == 2
  end

  test "technical failure blocks selection while semantic failure remains user-overridable" do
    assert {:ok, project} = Projects.create_project(%{name: "QC 选择"})
    [spec | _] = FakeEpisode.build_specs(project)
    assert {:ok, result} = Orchestrator.generate(spec, :shot_keyframe, project)

    File.write!(Assets.absolute_path(result.asset), "corrupted")
    assert {:ok, hard_fail} = Quality.run_technical(result.asset, spec)
    assert hard_fail.status == :fail
    assert hard_fail.blocking
    assert {:error, :technical_qc_failed} = Quality.select(project, "blocked", spec, result.asset)
  end

  test "semantic failure can be explicitly accepted and replacing a selection preserves history" do
    assert {:ok, project} = Projects.create_project(%{name: "QC 人工裁决"})
    [first_spec, second_spec | _] = FakeEpisode.build_specs(project)
    assert {:ok, first} = Orchestrator.generate(first_spec, :shot_keyframe, project)
    assert {:ok, second} = Orchestrator.generate(second_spec, :shot_keyframe, project)

    assert {:ok, original} = Quality.select(project, "shot:S001", first.spec, first.asset)
    assert {:ok, semantic_fail} = Quality.run_semantic_fixture(second.asset, second.spec, :fail)
    refute semantic_fail.blocking

    assert {:ok, replacement} =
             Quality.select(project, "shot:S001", second.spec, second.asset, note: "人工接受语义偏差")

    assert replacement.status == :active
    assert replacement.accepted_semantic_failure
    assert replacement.note == "人工接受语义偏差"
    assert Repo.get!(SelectionDecision, original.id).status == :superseded

    assert Repo.aggregate(
             from(decision in SelectionDecision,
               where: decision.slot_key == "shot:S001" and decision.status == :active
             ),
             :count
           ) == 1
  end
end
