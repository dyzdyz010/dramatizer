defmodule Dramatizer.Quality.SemanticQCTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.{SelectionDecision, SemanticQC, TechnicalQC}
  alias Dramatizer.Repo

  @dimensions ~w(identity_variant wardrobe location lighting key_props must_forbid composition camera action expression style artifacts)

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-semantic-qc-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "语义 QC"})
    assert {:ok, candidate} = store_image(project, "candidate")
    assert {:ok, reference} = store_image(project, "reference")
    assert {:ok, previous_asset} = store_image(project, "previous")
    assert {:ok, next_asset} = store_image(project, "next")
    assert {:ok, far_asset} = store_image(project, "far")

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{
                 "shot_id" => "S002",
                 "must_include" => ["林夏", "信件"],
                 "must_forbid" => ["现代广告牌"],
                 "camera" => "low_angle",
                 "action" => "走入车站"
               }
             })

    assert {:ok, _technical} = TechnicalQC.run(candidate, spec)

    %{
      project: project,
      candidate: candidate,
      reference: reference,
      previous: previous_asset,
      next: next_asset,
      far: far_asset,
      spec: spec
    }
  end

  test "builds exact multimodal evidence from candidate, references, and direct selected neighbors",
       context do
    test_pid = self()
    output = semantic_output("fail")

    evaluator = fn snapshot, _attempt ->
      send(test_pid, {:snapshot, snapshot})
      {:ok, %{output: output, external_request_id: "eval-1", usage: %{"total_tokens" => 42}}}
    end

    neighbors = [
      {:previous, selection(context.previous)},
      {:next, selection(context.next)},
      {:far, selection(context.far)}
    ]

    assert {:ok, report} =
             SemanticQC.run(context.candidate, context.spec, context.project,
               reference_assets: [context.reference],
               selected_neighbors: neighbors,
               evaluator: evaluator
             )

    assert report.status == :fail
    refute report.blocking
    assert Map.keys(report.evidence["dimensions"]) |> Enum.sort() == Enum.sort(@dimensions)

    for dimension <- @dimensions do
      assert %{
               "status" => "fail",
               "confidence" => 0.75,
               "reason" => "fixture reason",
               "advice" => "fixture advice"
             } = report.evidence["dimensions"][dimension]
    end

    assert_receive {:snapshot, snapshot}
    assert snapshot.adapter == "openai_responses"
    assert snapshot.request_input["schema_name"] == "image_semantic_qc"
    [%{"role" => "user", "content" => content}] = snapshot.request_input["input"]

    images = Enum.filter(content, &(&1["type"] == "input_image"))
    assert length(images) == 4
    assert Enum.all?(images, &String.starts_with?(&1["image_url"], "data:image/png;base64,"))
    labels = Enum.map(images, & &1["detail_role"])

    assert labels == [
             "candidate",
             "reference",
             "previous_selected_neighbor",
             "next_selected_neighbor"
           ]

    refute Enum.any?(images, &(&1["asset_version_id"] == context.far.id))

    assert {:ok, decision} =
             Quality.select(context.project, "shot:S002", context.spec, context.candidate,
               note: "人工接受语义差异"
             )

    assert decision.accepted_semantic_failure
    assert decision.note == "人工接受语义差异"
  end

  test "warning, inconclusive, and evaluator failure never hard-block a technically valid asset",
       context do
    for status <- ~w(warning inconclusive) do
      evaluator = fn _snapshot, _attempt ->
        {:ok,
         %{output: semantic_output(status), external_request_id: "eval-#{status}", usage: %{}}}
      end

      assert {:ok, report} =
               SemanticQC.run(context.candidate, context.spec, context.project,
                 evaluator: evaluator,
                 evaluation_key: status
               )

      assert Atom.to_string(report.status) == status
      refute report.blocking

      assert {:ok, _decision} =
               Quality.select(context.project, "slot-#{status}", context.spec, context.candidate)
    end

    unavailable = fn _snapshot, _attempt ->
      {:error, :provider_unavailable, %{reason: :fixture}}
    end

    assert {:ok, failed_report} =
             SemanticQC.run(context.candidate, context.spec, context.project,
               evaluator: unavailable,
               evaluation_key: "unavailable"
             )

    assert failed_report.status == :evaluator_failed
    refute failed_report.blocking

    assert {:ok, _decision} =
             Quality.select(context.project, "slot-unavailable", context.spec, context.candidate)
  end

  test "semantic QC reserves before evaluator submission and settles unknown actual", context do
    assert {:ok, _budget} = Costs.set_budget(context.project, 100)

    evaluator = fn _snapshot, _attempt ->
      assert Costs.get_budget(context.project).reserved_micros == 30

      {:ok,
       %{
         output: semantic_output("pass"),
         external_request_id: "semantic-budget-1",
         request_id: "req-semantic-budget-1",
         usage: %{"total_tokens" => 15}
       }}
    end

    assert {:ok, report} =
             SemanticQC.run(context.candidate, context.spec, context.project,
               evaluator: evaluator,
               evaluation_key: "budget",
               task_override: %{params: %{"estimated_cost_micros" => 30}}
             )

    assert report.status == :pass
    assert Costs.get_budget(context.project).reserved_micros == 0

    entries =
      Repo.all(
        Ecto.Query.from(entry in CostEntry, where: entry.project_id == ^context.project.id)
      )

    assert Enum.count(entries, &(&1.entry_type == :actual)) == 1
    assert Enum.find(entries, &(&1.entry_type == :actual)).amount_micros == nil
  end

  defp semantic_output(status) do
    %{
      "dimensions" =>
        Map.new(@dimensions, fn dimension ->
          {dimension,
           %{
             "status" => status,
             "confidence" => 0.75,
             "reason" => "fixture reason",
             "advice" => "fixture advice"
           }}
        end)
    }
  end

  defp selection(asset) do
    %SelectionDecision{
      id: Ecto.UUID.generate(),
      status: :active,
      asset_version_id: asset.id
    }
  end

  defp store_image(project, key) do
    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => 540,
        "height" => 960,
        "seed" => key
      })

    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "semantic-qc",
        expected_mime: "image/png",
        idempotency_key: "semantic-qc-#{key}"
      })

    {:ok, staged} = Assets.stage_bytes(intent, Base.decode64!(generated["png_base64"]))
    Assets.finalize(staged, %{"origin" => "fixture"})
  end
end
