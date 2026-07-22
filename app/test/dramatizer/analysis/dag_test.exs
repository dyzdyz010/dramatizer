defmodule Dramatizer.Analysis.DAGTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.{AnalysisSnapshot, DAG}
  alias Dramatizer.Analysis.Jobs.AnalysisNodeJob
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Sources
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun
  alias Dramatizer.Workflow.WorkflowRun

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-analysis-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "分析 DAG"})
    assert {:ok, _document, source} = Sources.import(project, fixture_path("novel.txt"))
    %{project: project, source: source}
  end

  test "three full-text roots are independent and descendants unblock only after required success",
       context do
    assert {:ok, run, nodes} = DAG.start(context.project, [context.source.id])
    by_key = Map.new(nodes, &{&1.node_key, &1})

    for key <- ~w(people_relations places_props_world events_timeline) do
      assert by_key[key].status == :queued
      assert by_key[key].input_snapshot["whole_document"] =~ "林夏站在车站"
      assert by_key[key].input_snapshot["source_revision_ids"] == [context.source.id]
    end

    assert by_key["entity_merge"].status == :blocked
    assert by_key["episode_candidates"].status == :blocked
    assert by_key["conflict_check"].status == :blocked

    assert {:ok, people_running} = Workflow.transition_node(by_key["people_relations"], :running)

    assert {:ok, _people_done} =
             Workflow.transition_node(people_running, :succeeded, %{result: %{"items" => []}})

    assert [] == Workflow.queue_ready_nodes(run.id)

    assert {:ok, places_running} =
             Workflow.transition_node(by_key["places_props_world"], :running)

    assert {:ok, _places_done} =
             Workflow.transition_node(places_running, :succeeded, %{result: %{"items" => []}})

    assert [] == Workflow.queue_ready_nodes(run.id)

    assert {:ok, events_running} = Workflow.transition_node(by_key["events_timeline"], :running)

    assert {:ok, events_failed} =
             Workflow.transition_node(events_running, :failed, %{error_code: "fixture"})

    assert [] == Workflow.queue_ready_nodes(run.id)
    assert {:ok, retried} = Workflow.retry_node(events_failed)
    assert retried.run_count == 2
    assert Repo.get!(NodeRun, people_running.id).status == :succeeded

    assert {:ok, events_running_again} = Workflow.transition_node(retried, :running)

    assert {:ok, _events_done} =
             Workflow.transition_node(events_running_again, :succeeded, %{
               result: %{"items" => []}
             })

    assert [%NodeRun{node_key: "entity_merge", status: :queued}] =
             Workflow.queue_ready_nodes(run.id)
  end

  test "enqueue persists three root jobs without running a provider", context do
    assert {:ok, run} = Analysis.enqueue(context.project, [context.source.id])

    nodes = Repo.all(from node in NodeRun, where: node.workflow_run_id == ^run.id)
    roots = Enum.filter(nodes, &(&1.required_parent_keys == []))
    descendants = Enum.reject(nodes, &(&1.required_parent_keys == []))

    assert Enum.all?(roots, &(&1.status == :queued))
    assert Enum.all?(roots, &(&1.worker == inspect(AnalysisNodeJob)))
    assert Enum.all?(roots, &is_integer(&1.active_job_id))
    assert Enum.all?(descendants, &(&1.status == :blocked))
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(AnalysisSnapshot, :count) == 0

    jobs =
      Repo.all(from job in Oban.Job, where: job.worker == ^inspect(AnalysisNodeJob))

    assert length(jobs) == 3
    assert Enum.all?(jobs, &(Map.keys(&1.args) == ["node_run_id"]))

    assert {:ok, same_run} = Analysis.enqueue(context.project, [context.source.id])
    assert same_run.id == run.id

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == ^inspect(AnalysisNodeJob)),
             :count
           ) == 3
  end

  test "enqueue recovers runnable nodes from an idempotent legacy analysis run", context do
    assert {:ok, run, nodes} = DAG.start(context.project, [context.source.id])
    by_key = Map.new(nodes, &{&1.node_key, &1})

    assert {:ok, people_running} =
             Workflow.transition_node(by_key["people_relations"], :running)

    assert people_running.worker == nil
    assert people_running.active_job_id == nil

    assert {:ok, places_running} =
             Workflow.transition_node(by_key["places_props_world"], :running)

    assert {:ok, _places_succeeded} =
             Workflow.transition_node(places_running, :succeeded, %{result: %{"items" => []}})

    assert {:ok, events_running} =
             Workflow.transition_node(by_key["events_timeline"], :running)

    assert {:ok, _events_failed} =
             Workflow.transition_node(events_running, :failed, %{error_code: "provider_failed"})

    assert {:ok, failed_run} = Workflow.mark_run(run, :failed)
    assert failed_run.completed_at
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert {:ok, resumed} = Analysis.enqueue(context.project, [context.source.id])
    assert resumed.id == run.id
    assert resumed.status == :running
    assert resumed.completed_at == nil

    recovered =
      Repo.all(from node in NodeRun, where: node.workflow_run_id == ^run.id)
      |> Map.new(&{&1.node_key, &1})

    assert recovered["people_relations"].status == :queued
    assert recovered["people_relations"].run_count == 2
    assert recovered["people_relations"].worker == inspect(AnalysisNodeJob)
    assert is_integer(recovered["people_relations"].active_job_id)

    assert recovered["events_timeline"].status == :queued
    assert recovered["events_timeline"].run_count == 2
    assert recovered["events_timeline"].worker == inspect(AnalysisNodeJob)
    assert is_integer(recovered["events_timeline"].active_job_id)

    assert recovered["places_props_world"].status == :succeeded
    assert recovered["places_props_world"].active_job_id == nil
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "provider mode is part of analysis workflow identity", context do
    assert {:ok, fake_run} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :fake)

    assert {:ok, same_fake_run} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :fake)

    assert same_fake_run.id == fake_run.id
    assert fake_run.input_snapshot["execution"]["workflow_schema_version"] == 2

    assert {:ok, openai_run} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :openai)

    refute openai_run.id == fake_run.id

    modes =
      Repo.all(
        from node in NodeRun,
          where: node.workflow_run_id in ^[fake_run.id, openai_run.id],
          select: {node.workflow_run_id, node.input_snapshot["provider_mode"]}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    assert Enum.uniq(modes[fake_run.id]) == ["fake"]
    assert Enum.uniq(modes[openai_run.id]) == ["openai"]

    fake_node =
      Repo.one!(
        from node in NodeRun,
          where: node.workflow_run_id == ^fake_run.id and node.node_key == "people_relations"
      )

    assert fake_node.input_snapshot["task_config"] == %{
             "adapter" => "fixture",
             "credential_ref" => "none",
             "model" => "fixture-analysis-v1",
             "params" => %{}
           }
  end

  test "analysis nodes freeze their resolved task config and config changes create a new run",
       context do
    assert {:ok, _override} =
             Projects.put_model_override(context.project, :people_relations, %{
               model: "gpt-analysis-frozen",
               params: %{"reasoning" => %{"effort" => "low"}}
             })

    assert {:ok, first_run, first_nodes} =
             DAG.start(context.project, [context.source.id], provider_mode: :openai)

    first_node = Enum.find(first_nodes, &(&1.node_key == "people_relations"))
    assert first_node.input_snapshot["task_config"]["model"] == "gpt-analysis-frozen"
    assert first_node.input_snapshot["task_config"]["params"]["reasoning"]["effort"] == "low"

    assert {:ok, :openai, execution_opts} = AnalysisNodeJob.execution_options(first_node)
    assert execution_opts[:task_override].model == "gpt-analysis-frozen"
    assert execution_opts[:task_override].params["reasoning"]["effort"] == "low"

    assert {:ok, _override} =
             Projects.put_model_override(context.project, :people_relations, %{
               model: "gpt-analysis-new",
               params: %{"reasoning" => %{"effort" => "high"}}
             })

    assert {:ok, second_run, second_nodes} =
             DAG.start(context.project, [context.source.id], provider_mode: :openai)

    refute second_run.id == first_run.id
    assert first_node.input_snapshot["task_config"]["model"] == "gpt-analysis-frozen"

    second_node = Enum.find(second_nodes, &(&1.node_key == "people_relations"))
    assert second_node.input_snapshot["task_config"]["model"] == "gpt-analysis-new"

    owner = self()

    submitter = fn snapshot, _attempt ->
      send(owner, {:submitted_with, snapshot.model, snapshot.params})
      {:error, :provider_rejected, %{}}
    end

    assert {:ok, running} = Workflow.transition_node(first_node, :running)

    assert {:error, :provider_rejected, _details} =
             Analysis.perform_node(
               running,
               context.project,
               :openai,
               Keyword.put(execution_opts, :submitter, submitter)
             )

    assert_receive {:submitted_with, "gpt-analysis-frozen", frozen_params}
    assert frozen_params["reasoning"]["effort"] == "low"
  end

  test "analysis worker rejects legacy nodes without a frozen execution snapshot", context do
    assert {:ok, run} =
             Workflow.create_run(
               context.project,
               "whole_novel_analysis_v1",
               %{"source_revision_ids" => [context.source.id]},
               "legacy-unfrozen-analysis"
             )

    assert {:ok, node} =
             Workflow.add_node(
               run,
               "people_relations",
               %{"provider_mode" => "openai", "project_id" => context.project.id},
               []
             )

    assert {:error, :execution_snapshot_missing} = AnalysisNodeJob.execution_options(node)
  end

  test "submitted orphan attempts become unknown instead of being resubmitted", context do
    assert {:ok, run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)

    assert {:ok, spec} =
             Generation.create_spec(context.project, %{
               kind: running.node_key,
               payload: %{"node_run_id" => running.id, "node_run_count" => running.run_count}
             })

    assert {:ok, _snapshot, prepared} =
             Generation.prepare_attempt(spec, :people_relations, context.project, %{
               task_override: %{
                 adapter: "fixture",
                 credential_ref: "none",
                 model: "fixture-analysis-v1"
               },
               node_run_id: running.id,
               request_input: %{"input" => "fixture"},
               prompt_snapshot: %{}
             })

    assert {:ok, submitted} = Generation.transition_attempt(prepared, :submitted)
    assert {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    assert {:error, :unknown_remote_state} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :fake)

    assert Repo.get!(Attempt, submitted.id).status == :unknown_remote_state

    stored = Repo.get!(NodeRun, running.id)
    assert stored.status == :failed
    assert stored.error_code == "unknown_remote_state"
    assert stored.active_job_id == nil
    assert Repo.get!(WorkflowRun, run.id).status == :failed
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "an unknown failed node remains stable when no Attempt record is available", context do
    assert {:ok, run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)

    assert {:ok, failed} =
             Workflow.transition_node(running, :failed, %{
               error_code: "unknown_remote_state"
             })

    assert {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    assert {:error, :unknown_remote_state} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :fake)

    assert Repo.get!(NodeRun, failed.id).status == :failed
    assert Repo.get!(NodeRun, failed.id).error_code == "unknown_remote_state"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "root job insertion failure rolls back the entire analysis topology", context do
    assert {:error, %Ecto.Changeset{valid?: false}} =
             Analysis.enqueue(context.project, [context.source.id], job_options: [priority: 99])

    assert Repo.aggregate(
             from(run in WorkflowRun,
               where:
                 run.project_id == ^context.project.id and
                   run.definition_key == "whole_novel_analysis_v1"
             ),
             :count
           ) == 0

    assert Repo.aggregate(NodeRun, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "recursive Oban drain completes the six-node analysis and finalizes its snapshot",
       context do
    assert {:ok, run} = Analysis.enqueue(context.project, [context.source.id])

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    assert %AnalysisSnapshot{workflow_run_id: run_id} =
             Repo.get_by!(AnalysisSnapshot, workflow_run_id: run.id)

    assert run_id == run.id
    assert Repo.get!(Dramatizer.Workflow.WorkflowRun, run.id).status == :succeeded

    assert Repo.all(from node in NodeRun, where: node.workflow_run_id == ^run.id)
           |> Enum.all?(&(&1.status == :succeeded))
  end

  test "worker retry reuses a succeeded provider attempt after a lifecycle crash", context do
    assert {:ok, _run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)

    assert {:ok, first_result} = Analysis.perform_node(running, context.project, :fake)
    attempt_count = Repo.aggregate(Attempt, :count)

    assert {:ok, recovered_result} = Analysis.perform_node(running, context.project, :fake)
    assert recovered_result == first_result
    assert Repo.aggregate(Attempt, :count) == attempt_count
  end

  test "ownership recovery reuses a succeeded provider attempt across node run counts", context do
    assert {:ok, run, nodes} =
             DAG.start(context.project, [context.source.id], provider_mode: :fake)

    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)
    assert {:ok, _result} = Analysis.perform_node(running, context.project, :fake)

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.node_run_id == ^running.id),
             :count
           ) ==
             1

    assert {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    assert {:ok, resumed} =
             Analysis.enqueue(context.project, [context.source.id], provider_mode: :fake)

    assert resumed.id == run.id
    assert Repo.get!(NodeRun, running.id).run_count == 2

    assert %{failure: 0, snoozed: 0, success: 6} =
             Oban.drain_queue(queue: :workflow, with_recursion: true, with_safety: false)

    assert Repo.get!(NodeRun, running.id).status == :succeeded

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.node_run_id == ^running.id),
             :count
           ) ==
             1
  end

  test "retry refuses a failed node whose provider outcome is unknown", context do
    assert {:ok, run, nodes} =
             DAG.start(context.project, [context.source.id], provider_mode: :fake)

    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)

    assert {:ok, spec} =
             Generation.create_spec(context.project, %{
               kind: running.node_key,
               payload: %{"node_run_id" => running.id}
             })

    assert {:ok, _snapshot, prepared} =
             Generation.prepare_attempt(spec, :people_relations, context.project, %{
               task_override: %{
                 adapter: "fixture",
                 credential_ref: "none",
                 model: "fixture-analysis-v1"
               },
               node_run_id: running.id,
               request_input: %{"input" => "fixture"},
               prompt_snapshot: %{}
             })

    assert {:ok, submitted} = Generation.transition_attempt(prepared, :submitted)

    assert {:ok, failed} =
             Workflow.transition_node(running, :failed, %{error_code: "provider_failed"})

    assert {:ok, _failed_run} = Workflow.mark_run(run, :failed)

    assert {:error, :unknown_remote_state} = Analysis.retry_node(failed)
    assert Repo.get!(Attempt, submitted.id).status == :unknown_remote_state

    assert %NodeRun{status: :failed, error_code: "unknown_remote_state"} =
             Repo.get!(NodeRun, failed.id)

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "remote submission timeout is not retried as a new analysis Attempt", context do
    assert {:ok, _run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))
    assert {:ok, running} = Workflow.transition_node(node, :running)
    owner = self()

    submitter = fn _snapshot, _attempt ->
      send(owner, :submitted)
      {:error, :provider_timeout, %{reason: :socket_timeout}}
    end

    options = [submitter: submitter, task_override: %{params: %{"estimated_cost_micros" => 0}}]

    assert {:error, :unknown_remote_state, _details} =
             Analysis.perform_node(running, context.project, :openai, options)

    assert_receive :submitted

    assert {:error, :unknown_remote_state, _details} =
             Analysis.perform_node(running, context.project, :openai, options)

    refute_receive :submitted
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.one!(Attempt).status == :unknown_remote_state
  end

  test "structured repair creates at most three Attempts and finalizes an immutable snapshot",
       context do
    assert {:ok, run, nodes} = DAG.start(context.project, [context.source.id])
    people = Enum.find(nodes, &(&1.node_key == "people_relations"))

    invalid_json = "{bad"
    missing_locator = %{"items" => [item("person:p1", "source_grounded", [])]}
    valid = %{"items" => [item("person:p1", "source_grounded", [locator(context.source.id)])]}

    assert {:ok, completed} =
             Analysis.run_node(people, context.project, [invalid_json, missing_locator, valid])

    assert completed.status == :succeeded
    assert length(completed.result["provider_request_snapshot_ids"]) == 3
    assert Repo.aggregate(Attempt, :count) == 3

    request =
      Dramatizer.Repo.get!(
        Dramatizer.Generation.ProviderRequestSnapshot,
        hd(completed.result["provider_request_snapshot_ids"])
      )

    assert request.request_input["input"] =~ "人物与关系抽取器"
    assert request.request_input["input"] =~ context.source.id
    assert request.prompt_snapshot["core_version"] == "v1"
    assert request.prompt_snapshot["schema_version"] == "analysis-schema-v2"
    assert byte_size(request.prompt_snapshot["core_hash"]) == 64
    assert byte_size(request.prompt_snapshot["schema_hash"]) == 64
    assert byte_size(request.prompt_snapshot["config_hash"]) == 64
    assert byte_size(request.prompt_snapshot["prompt_hash"]) == 64

    complete_remaining_nodes(run.id, people.id)
    assert {:ok, snapshot} = DAG.finalize(run)
    assert snapshot.source_revision_ids == [context.source.id]
    assert map_size(snapshot.node_results) == 6
    assert length(snapshot.task_snapshot_ids) == 3

    assert_raise Postgrex.Error, ~r/immutable_record/, fn ->
      Repo.update_all(from(item in AnalysisSnapshot, where: item.id == ^snapshot.id),
        set: [content_hash: String.duplicate("0", 64)]
      )
    end
  end

  test "two failed repairs end in a stable failed node after the initial Attempt", context do
    assert {:ok, _run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))

    assert {:error, :structured_validation_failed, failed} =
             Analysis.run_node(node, context.project, ["{bad", "{bad", "{bad", %{"items" => []}])

    assert failed.status == :failed
    assert failed.error_code == "structured_validation_failed"
    assert Repo.aggregate(Attempt, :count) == 3
  end

  test "live analysis reserves before provider submission and settles unknown actual", context do
    assert {:ok, _budget} = Costs.set_budget(context.project, 100)
    assert {:ok, _run, nodes} = DAG.start(context.project, [context.source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))

    submitter = fn _snapshot, _attempt ->
      assert Costs.get_budget(context.project).reserved_micros == 40

      {:ok,
       %{
         output: %{
           "items" => [
             item(
               "person:live",
               "source_grounded",
               [locator(context.source.id)]
             )
           ]
         },
         external_request_id: "analysis-live-1",
         request_id: "req-analysis-live-1",
         usage: %{"total_tokens" => 20}
       }}
    end

    assert {:ok, completed} =
             Analysis.run_node_live(node, context.project,
               submitter: submitter,
               task_override: %{params: %{"estimated_cost_micros" => 40}}
             )

    assert completed.status == :succeeded
    assert Costs.get_budget(context.project).reserved_micros == 0
    entries = Repo.all(from entry in CostEntry, where: entry.project_id == ^context.project.id)
    assert Enum.map(entries, & &1.entry_type) |> Enum.sort() == [:actual, :estimate, :reservation]
    assert Enum.find(entries, &(&1.entry_type == :actual)).amount_micros == nil
  end

  defp complete_remaining_nodes(run_id, except_id) do
    Repo.all(
      from node in NodeRun, where: node.workflow_run_id == ^run_id and node.id != ^except_id
    )
    |> Enum.each(fn node ->
      current = Repo.get!(NodeRun, node.id)

      current =
        if current.status == :blocked do
          current
          |> Ecto.Changeset.change(status: :queued)
          |> Repo.update!()
        else
          current
        end

      {:ok, running} = Workflow.transition_node(current, :running)
      {:ok, _done} = Workflow.transition_node(running, :succeeded, %{result: %{"items" => []}})
    end)
  end

  defp item(id, semantics, locators) do
    %{
      "id" => id,
      "kind" => "person",
      "name" => "林夏",
      "source_semantics" => semantics,
      "locators" => locators,
      "references" => [],
      "data" => %{}
    }
  end

  defp locator(source_id) do
    %{"source_revision_id" => source_id, "start_offset" => 0, "end_offset" => 2}
  end

  defp fixture_path(name), do: Path.expand("../../support/fixtures/sources/#{name}", __DIR__)
end
