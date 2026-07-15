defmodule Dramatizer.Analysis.DAGTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.{AnalysisSnapshot, DAG}
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Sources
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun

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
