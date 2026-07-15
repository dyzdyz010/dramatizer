defmodule Dramatizer.Acceptance.FakeMVPTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Directing.Compiler
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, GenerationSpec, Orchestrator, ProviderRequestSnapshot}
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.QualityReport
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Sources
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.{RenderRecipe, TimelineVersion}
  alias Dramatizer.Workflow.InboxMessage

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-at-fake-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  @tag timeout: 240_000
  test "AT-001 Fake 三镜头闭环与最终 Clip 全谱系" do
    assert {:ok, project} = Projects.create_project(%{name: "AT-001 三镜头"})
    assert {:ok, _document, source} = Sources.import(project, source_fixture())

    narrative =
      confirmed(project, :narrative, %{
        "episode_id" => "E001",
        "source_revision_ids" => [source.id],
        "dialogue_events" => [
          dialogue("D001", "S001", "雨还没有停。", 100, 1_400),
          dialogue("D002", "S002", "这封信不是我写的。", 1_700, 3_100),
          dialogue("D003", "S003", "寄信的人就在附近。", 3_400, 4_900)
        ]
      })

    visual =
      confirmed(project, :visual_design, %{
        "objects" => [%{"id" => "character:lead", "type" => "character"}]
      })

    reference =
      confirmed(project, :reference_set, %{
        "visual_design_revision_id" => visual.id,
        "primary_assets" => %{}
      })

    shot_plan = confirmed(project, :shot_plan, shot_plan_payload())

    assert {:ok, compiled_revision} =
             Compiler.compile_revision(
               project,
               %{
                 narrative: narrative,
                 visual_design: visual,
                 reference_set: reference,
                 shot_plan: shot_plan
               },
               source_revision_ids: [source.id]
             )

    selections =
      compiled_revision.payload["specs"]
      |> Enum.map(fn compiled ->
        shot_id = compiled["shot_id"]
        payload = Map.put(compiled["payload"], "shot_id", shot_id)

        candidates =
          for candidate_index <- 0..1 do
            assert {:ok, spec} =
                     Generation.create_spec(project, %{
                       revision_id: compiled_revision.id,
                       kind: "shot_keyframe",
                       candidate_index: candidate_index,
                       formal: true,
                       payload: payload
                     })

            assert {:ok, generated} = Orchestrator.generate(spec, :shot_keyframe, project)
            generated
          end

        chosen = hd(candidates)

        assert {:ok, selection} =
                 Quality.select(project, "shot:#{shot_id}", chosen.spec, chosen.asset)

        {shot_id, selection}
      end)
      |> Map.new()

    assert map_size(selections) == 3
    assert {:ok, timeline} = Timeline.create(project, narrative, shot_plan, selections)
    assert {:ok, preview} = RenderRecipe.preview(timeline)
    assert {:ok, preview_rendered} = Timeline.render(preview)
    assert preview_rendered.status == :rendered
    assert preview_rendered.width == 540

    assert {:ok, version} = Timeline.freeze(timeline)
    assert {:ok, formal} = RenderRecipe.formal(version)
    assert {:ok, rendered} = Timeline.render(formal)
    assert rendered.status == :rendered
    assert rendered.technical_qc["status"] == "pass"

    assert length(Timeline.list_clips(timeline)) == 3
    assert Repo.get!(TimelineVersion, version.id).content_hash == version.content_hash

    for clip <- Timeline.list_clips(timeline) do
      asset = Assets.get_asset!(clip.asset_version_id)
      attempt = Repo.get!(Attempt, asset.lineage["attempt_id"])
      request = Repo.get!(ProviderRequestSnapshot, attempt.provider_request_snapshot_id)
      spec = Repo.get!(GenerationSpec, request.generation_spec_id)
      generation_revision = Revisions.get_revision!(spec.revision_id)

      assert generation_revision.id == compiled_revision.id

      assert get_in(generation_revision.payload, ["frozen_inputs", "revisions", "shot_plan", "id"]) ==
               shot_plan.id

      assert get_in(generation_revision.payload, [
               "frozen_inputs",
               "revisions",
               "visual_design",
               "id"
             ]) ==
               visual.id

      assert get_in(generation_revision.payload, ["frozen_inputs", "revisions", "narrative", "id"]) ==
               narrative.id

      assert narrative.payload["source_revision_ids"] == [source.id]
      assert Repo.get!(SourceRevision, source.id).project_id == project.id

      assert Repo.aggregate(
               from(report in QualityReport, where: report.asset_version_id == ^asset.id),
               :count
             ) == 2

      assert attempt.status == :succeeded
      assert request.secrets_excluded
    end
  end

  test "AT-002 重复提交与乱序回调恢复后无重复资产和成本" do
    assert {:ok, project} = Projects.create_project(%{name: "AT-002 幂等恢复"})

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{"shot_id" => "S001", "width" => 270, "height" => 480}
             })

    fault = %{
      fail_on_attempt: 1,
      duplicate_callbacks: 3,
      out_of_order_callbacks: true,
      cost_micros: 31
    }

    assert {:error, :provider_rejected} =
             Orchestrator.generate(spec, :shot_keyframe, project, fault_profile: fault)

    assert {:ok, first} =
             Orchestrator.generate(spec, :shot_keyframe, project, fault_profile: fault)

    assert {:ok, repeated} =
             Orchestrator.generate(spec, :shot_keyframe, project, fault_profile: fault)

    assert first.asset.id == repeated.asset.id
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(InboxMessage, :count) == 1
    assert Repo.aggregate(from(cost in CostEntry, where: cost.entry_type == :actual), :count) == 1
  end

  defp confirmed(project, kind, payload) do
    assert {:ok, draft} = Revisions.create_draft(project, kind, payload, %{"acceptance" => true})
    assert {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  defp dialogue(id, shot_id, text, start_ms, end_ms) do
    %{
      "id" => id,
      "shot_id" => shot_id,
      "text" => text,
      "start_ms" => start_ms,
      "end_ms" => end_ms,
      "style" => %{"position" => "safe_bottom"}
    }
  end

  defp shot_plan_payload do
    %{
      "scenes" => [%{"id" => "SC001"}],
      "shots" =>
        Enum.map(1..3, fn index ->
          id = "S#{String.pad_leading(to_string(index), 3, "0")}"

          %{
            "id" => id,
            "scene_id" => "SC001",
            "minimum_duration_ms" => 1_200,
            "preferred_duration_ms" => 1_700,
            "maximum_duration_ms" => 2_300,
            "camera" => Enum.at(~w(push_in pan_left pull_out), index - 1)
          }
        end)
    }
  end

  defp source_fixture do
    Path.expand("../../support/fixtures/sources/novel.txt", __DIR__)
  end
end
