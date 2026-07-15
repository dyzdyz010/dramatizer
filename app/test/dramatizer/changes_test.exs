defmodule Dramatizer.ChangesTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Changes
  alias Dramatizer.Changes.{ChangeNode, ChangeSet, StaleRecord}
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Repo
  alias Dramatizer.Revisions

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-changes-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "变更传播"})
    old_revision = confirmed(project, :visual_design, %{"version" => 1})
    new_revision = confirmed(project, :visual_design, %{"version" => 2})
    %{project: project, old_revision: old_revision, new_revision: new_revision}
  end

  test "preview traverses exact dependencies without side effects and confirmation preserves history",
       context do
    {spec, asset, technical, selection} =
      selected_candidate(context.project, "affected", "slot:affected")

    {:ok, unrelated_spec} =
      Generation.create_spec(context.project, %{
        kind: "shot_keyframe",
        payload: %{"shot_id" => "unrelated"}
      })

    :ok =
      Changes.add_dependency(
        context.project,
        {"revision", context.old_revision.id},
        {"generation_spec", spec.id}
      )

    :ok =
      Changes.add_dependency(
        context.project,
        {"generation_spec", spec.id},
        {"asset_version", asset.id}
      )

    :ok =
      Changes.add_dependency(
        context.project,
        {"asset_version", asset.id},
        {"quality_report", technical.id}
      )

    :ok =
      Changes.add_dependency(
        context.project,
        {"asset_version", asset.id},
        {"selection_decision", selection.id}
      )

    counts_before = counts()

    assert {:ok, impact} =
             Changes.preview(context.project, context.old_revision, context.new_revision)

    assert counts() == counts_before

    ids = MapSet.new(impact.targets, & &1.id)
    assert MapSet.member?(ids, spec.id)
    assert MapSet.member?(ids, asset.id)
    assert MapSet.member?(ids, technical.id)
    assert MapSet.member?(ids, selection.id)
    refute MapSet.member?(ids, unrelated_spec.id)
    assert impact.diff["old_hash"] == context.old_revision.content_hash
    assert impact.diff["new_hash"] == context.new_revision.content_hash

    assert {:ok, change_set} = Changes.confirm(impact, :all)
    assert change_set.status == :confirmed
    assert change_set.graph_epoch == impact.graph_epoch
    assert change_set.diff == impact.diff
    assert Repo.aggregate(ChangeNode, :count) == 4

    generation_jobs =
      Repo.aggregate(
        from(job in Oban.Job,
          where:
            job.queue == "generation" or
              job.worker in [
                "Dramatizer.Generation.Adapters.OpenAIImages",
                "Dramatizer.Generation.Adapters.OpenAIResponses"
              ]
        ),
        :count
      )

    assert generation_jobs == 0
    assert {:ok, completed} = Changes.resume(change_set)
    assert completed.status == :succeeded

    assert Repo.get!(SelectionDecision, selection.id).asset_version_id == asset.id
    assert Assets.get_asset!(asset.id).blob_hash == asset.blob_hash

    assert Repo.get_by!(StaleRecord, subject_type: "selection_decision", subject_id: selection.id).resolution ==
             :unresolved

    assert {:ok, pinned} = Changes.resolve_stale(selection, :pin_old_input)
    assert pinned.resolution == :pin_old_input
    assert Repo.get!(SelectionDecision, selection.id).status == :active
  end

  test "unsubmitted old work is superseded while submitted work reconciles under old input",
       context do
    {:ok, spec} =
      Generation.create_spec(context.project, %{
        kind: "shot_keyframe",
        payload: %{"shot_id" => "old-work"}
      })

    {:ok, snapshot_prepared, prepared} =
      Generation.prepare_attempt(spec, :shot_keyframe, context.project, %{
        task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
        request_input: %{"generation_spec" => spec.payload, "variant" => "prepared"}
      })

    {:ok, snapshot_submitted, submitted_prepared} =
      Generation.prepare_attempt(spec, :shot_keyframe, context.project, %{
        task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
        request_input: %{"generation_spec" => spec.payload, "variant" => "submitted"}
      })

    assert snapshot_prepared.id != snapshot_submitted.id
    assert {:ok, submitted} = Generation.transition_attempt(submitted_prepared, :submitted)

    for attempt <- [prepared, submitted] do
      :ok =
        Changes.add_dependency(
          context.project,
          {"revision", context.old_revision.id},
          {"attempt", attempt.id}
        )
    end

    assert {:ok, impact} =
             Changes.preview(context.project, context.old_revision, context.new_revision)

    assert {:ok, change_set} = Changes.confirm(impact, :all)
    assert {:ok, _completed} = Changes.resume(change_set)

    assert Repo.get!(Attempt, prepared.id).status == :superseded
    assert Repo.get!(Attempt, submitted.id).status == :submitted

    stale = Repo.get_by!(StaleRecord, subject_type: "attempt", subject_id: submitted.id)
    assert stale.reason == "old_input_in_flight"
    assert stale.resolution == :unresolved

    assert {:ok, terminal} =
             Generation.transition_attempt(Repo.get!(Attempt, submitted.id), :succeeded, %{
               response_metadata: %{"reconciled_under" => "old_input"}
             })

    assert terminal.status == :succeeded

    assert Repo.get_by!(StaleRecord, subject_type: "attempt", subject_id: submitted.id).id ==
             stale.id
  end

  test "partial failure resumes only failed nodes without repeating successes or costs",
       context do
    :ok =
      Changes.add_dependency(
        context.project,
        {"revision", context.old_revision.id},
        {"generation_spec", Ecto.UUID.generate()},
        %{"fail_once" => true}
      )

    :ok =
      Changes.add_dependency(
        context.project,
        {"revision", context.old_revision.id},
        {"generation_spec", Ecto.UUID.generate()}
      )

    assert {:ok, impact} =
             Changes.preview(context.project, context.old_revision, context.new_revision)

    assert Enum.any?(impact.targets, &(&1.metadata["fail_once"] == true))
    assert {:ok, change_set} = Changes.confirm(impact, :all)
    costs_before = Repo.aggregate(CostEntry, :count)

    assert Repo.exists?(
             from node in ChangeNode,
               where: node.change_set_id == ^change_set.id,
               where:
                 fragment(
                   "?->'target'->'metadata'->>'fail_once' = 'true'",
                   node.input_snapshot
                 )
           )

    fail_node =
      Repo.one!(
        from node in ChangeNode,
          where: node.change_set_id == ^change_set.id,
          where:
            fragment(
              "?->'target'->'metadata'->>'fail_once' = 'true'",
              node.input_snapshot
            )
      )

    assert {fail_node.status, fail_node.attempt_count} == {:pending, 0}
    assert get_in(fail_node.input_snapshot, ["target", "metadata", "fail_once"]) === true

    assert {:ok, partial} = Changes.resume(change_set)

    node_states =
      Repo.all(from node in ChangeNode, where: node.change_set_id == ^change_set.id)
      |> Enum.map(&{&1.status, &1.attempt_count, &1.error_code})

    assert Enum.count(node_states, fn {status, _, _} -> status == :failed end) == 1

    assert partial.status == :partial_failed

    succeeded_before =
      Repo.one!(
        from node in ChangeNode,
          where: node.change_set_id == ^change_set.id and node.status == :succeeded
      )

    assert succeeded_before.attempt_count == 1
    assert {:ok, completed} = Changes.resume(partial)
    assert completed.status == :succeeded
    assert Repo.get!(ChangeNode, succeeded_before.id).attempt_count == 1
    assert Repo.aggregate(CostEntry, :count) == costs_before
  end

  test "changing one selected shot debounces semantic QC to that shot and direct neighbors",
       context do
    _initial_selections =
      for index <- 1..5 do
        {_spec, _asset, _technical, selection} =
          selected_candidate(context.project, "neighbor-#{index}", "shot:S00#{index}")

        selection
      end

    ordered_slots = Enum.map(1..5, &"shot:S00#{&1}")

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "Dramatizer.Quality.Jobs.SemanticQCJob"
             ),
             :count
           ) == 0

    {_replacement_spec, _replacement_asset, _technical, replacement} =
      selected_candidate(context.project, "neighbor-3-replacement", "shot:S003")

    jobs =
      Repo.all(
        from job in Oban.Job,
          where: job.worker == "Dramatizer.Quality.Jobs.SemanticQCJob",
          order_by: [asc: job.inserted_at]
      )

    assert length(jobs) == 3

    targeted =
      jobs
      |> Enum.map(& &1.args["asset_version_id"])
      |> MapSet.new()

    expected =
      Repo.all(
        from selection in SelectionDecision,
          where:
            selection.project_id == ^context.project.id and selection.status == :active and
              selection.slot_key in ^Enum.slice(ordered_slots, 1, 3),
          select: selection.asset_version_id
      )
      |> MapSet.new()

    assert targeted == expected
    assert replacement.asset_version_id in targeted

    middle_job = Enum.find(jobs, &(&1.args["asset_version_id"] == replacement.asset_version_id))

    assert Map.keys(middle_job.args["selected_neighbor_ids"]) |> Enum.sort() ==
             ["next", "previous"]

    assert {:ok, duplicate_jobs} =
             Changes.schedule_neighbor_qc(context.project, ordered_slots, "shot:S003")

    assert Enum.all?(duplicate_jobs, &(&1.conflict? == true))

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "Dramatizer.Quality.Jobs.SemanticQCJob"
             ),
             :count
           ) == 3
  end

  defp counts do
    %{
      change_sets: Repo.aggregate(ChangeSet, :count),
      change_nodes: Repo.aggregate(ChangeNode, :count),
      stale_records: Repo.aggregate(StaleRecord, :count)
    }
  end

  defp selected_candidate(project, key, slot) do
    {:ok, spec} =
      Generation.create_spec(project, %{
        kind: "shot_keyframe",
        payload: %{"shot_id" => key}
      })

    {:ok, asset} = store_image(project, key)
    {:ok, technical} = Quality.run_technical(asset, spec)
    {:ok, selection} = Quality.select(project, slot, spec, asset)
    {spec, asset, technical, selection}
  end

  defp store_image(project, key) do
    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => 64,
        "height" => 96,
        "seed" => key
      })

    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "change-test",
        expected_mime: "image/png",
        idempotency_key: "change-test-#{key}"
      })

    {:ok, staged} = Assets.stage_bytes(intent, Base.decode64!(generated["png_base64"]))
    Assets.finalize(staged, %{"origin" => "fixture", "formal" => true})
  end

  defp confirmed(project, kind, payload) do
    {:ok, draft} = Revisions.create_draft(project, kind, payload, %{"fixture" => true})
    {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end
end
