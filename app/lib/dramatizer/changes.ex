defmodule Dramatizer.Changes do
  @moduledoc "Explicit impact previews, frozen ChangeSets, stale resolution, and bounded recomputation."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.CanonicalJSON

  alias Dramatizer.Changes.{
    ChangeNode,
    ChangeSet,
    DependencyEdge,
    Impact,
    StaleRecord
  }

  alias Dramatizer.Changes.Jobs.ChangeNodeJob
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality
  alias Dramatizer.Quality.Jobs.SemanticQCJob
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Repo
  alias Dramatizer.Revisions.Revision
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun

  def add_dependency(project, upstream, downstream, metadata \\ %{})

  def add_dependency(
        %Project{id: project_id},
        {upstream_type, upstream_id},
        {downstream_type, downstream_id},
        metadata
      ) do
    graph_epoch = Map.get(metadata, "graph_epoch", 1)

    %DependencyEdge{}
    |> DependencyEdge.create_changeset(%{
      project_id: project_id,
      upstream_type: upstream_type,
      upstream_id: upstream_id,
      downstream_type: downstream_type,
      downstream_id: downstream_id,
      graph_epoch: graph_epoch,
      metadata: Map.delete(metadata, "graph_epoch")
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [
        :project_id,
        :upstream_type,
        :upstream_id,
        :downstream_type,
        :downstream_id,
        :graph_epoch
      ]
    )

    :ok
  end

  def preview(
        %Project{id: project_id},
        %Revision{project_id: project_id} = old_revision,
        %Revision{project_id: project_id} = new_revision
      ) do
    edges = Repo.all(from edge in DependencyEdge, where: edge.project_id == ^project_id)
    adjacency = Enum.group_by(edges, &{&1.upstream_type, &1.upstream_id})
    targets = traverse([{"revision", old_revision.id}], adjacency, MapSet.new(), [])
    graph_epoch = edges |> Enum.map(& &1.graph_epoch) |> Enum.max(fn -> 1 end)

    diff = %{
      "kind" => Atom.to_string(old_revision.kind),
      "old_revision_id" => old_revision.id,
      "new_revision_id" => new_revision.id,
      "old_hash" => old_revision.content_hash,
      "new_hash" => new_revision.content_hash,
      "changed" => old_revision.content_hash != new_revision.content_hash
    }

    {:ok,
     %Impact{
       project_id: project_id,
       old_revision_id: old_revision.id,
       new_revision_id: new_revision.id,
       graph_epoch: graph_epoch,
       diff: diff,
       targets: targets
     }}
  end

  def preview(%Project{}, %Revision{}, %Revision{}), do: {:error, :revision_project_mismatch}

  def confirm(%Impact{} = impact, selected_targets) do
    selected =
      case selected_targets do
        :all -> impact.targets
        ids when is_list(ids) -> Enum.filter(impact.targets, &(&1.id in ids))
      end

    actions = Enum.map(selected, &Map.put(&1, :action, action_for(&1)))
    selected_ids = Enum.map(selected, & &1.id)

    idempotency_key =
      CanonicalJSON.hash(%{
        "old_revision_id" => impact.old_revision_id,
        "new_revision_id" => impact.new_revision_id,
        "graph_epoch" => impact.graph_epoch,
        "selected_target_ids" => selected_ids
      })

    Repo.transaction(fn ->
      %ChangeSet{}
      |> ChangeSet.create_changeset(%{
        project_id: impact.project_id,
        old_revision_id: impact.old_revision_id,
        new_revision_id: impact.new_revision_id,
        status: :confirmed,
        diff: impact.diff,
        graph_epoch: impact.graph_epoch,
        selected_target_ids: selected_ids,
        actions: %{"items" => Enum.map(actions, &stringify/1)},
        idempotency_key: idempotency_key,
        confirmed_at: DateTime.utc_now()
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:idempotency_key])

      change_set = Repo.get_by!(ChangeSet, idempotency_key: idempotency_key)

      Enum.each(actions, fn target ->
        node_key = "#{target.action}:#{target.type}:#{target.id}"

        input = %{
          "target" => stringify(target),
          "old_revision_id" => impact.old_revision_id,
          "new_revision_id" => impact.new_revision_id,
          "graph_epoch" => impact.graph_epoch
        }

        %ChangeNode{}
        |> ChangeNode.create_changeset(%{
          change_set_id: change_set.id,
          node_key: node_key,
          target_type: target.type,
          target_id: target.id,
          action: target.action,
          status: :pending,
          input_snapshot: input,
          input_hash: CanonicalJSON.hash(input)
        })
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:change_set_id, :node_key]
        )

        node = Repo.get_by!(ChangeNode, change_set_id: change_set.id, node_key: node_key)

        %{"change_node_id" => node.id}
        |> ChangeNodeJob.new(unique: [period: 300, fields: [:worker, :args]])
        |> Oban.insert()
      end)

      change_set
    end)
    |> unwrap()
  end

  def resume(%ChangeSet{id: id}) do
    change_set = Repo.get!(ChangeSet, id)

    change_set
    |> ChangeSet.status_changeset(%{status: :running, completed_at: nil})
    |> Repo.update!()

    Repo.all(
      from node in ChangeNode,
        where: node.change_set_id == ^id and node.status in [:pending, :failed],
        order_by: [asc: node.inserted_at]
    )
    |> Enum.each(&run_change_node(&1.id))

    nodes = Repo.all(from node in ChangeNode, where: node.change_set_id == ^id)
    failed? = Enum.any?(nodes, &(&1.status == :failed))
    pending? = Enum.any?(nodes, &(&1.status in [:pending, :running]))
    status = if failed? or pending?, do: :partial_failed, else: :succeeded

    updated =
      change_set
      |> ChangeSet.status_changeset(%{
        status: status,
        completed_at: if(status == :succeeded, do: DateTime.utc_now(), else: nil)
      })
      |> Repo.update!()

    {:ok, updated}
  end

  def run_change_node(node_id) do
    node = Repo.get!(ChangeNode, node_id)

    if node.status == :succeeded do
      {:ok, node}
    else
      running =
        node
        |> ChangeNode.execution_changeset(%{
          status: :running,
          result: node.result,
          error_code: nil,
          attempt_count: node.attempt_count + 1
        })
        |> Repo.update!()

      fail_once = get_in(running.input_snapshot, ["target", "metadata", "fail_once"]) == true

      if fail_once and node.attempt_count == 0 do
        failed =
          running
          |> ChangeNode.execution_changeset(%{
            status: :failed,
            result: %{},
            error_code: "deterministic_fixture_failure",
            attempt_count: running.attempt_count
          })
          |> Repo.update!()

        {:error, :deterministic_fixture_failure, failed}
      else
        case perform_action(running) do
          {:ok, result} ->
            succeeded =
              running
              |> ChangeNode.execution_changeset(%{
                status: :succeeded,
                result: stringify(result),
                error_code: nil,
                attempt_count: running.attempt_count
              })
              |> Repo.update!()

            {:ok, succeeded}

          {:error, reason} ->
            failed =
              running
              |> ChangeNode.execution_changeset(%{
                status: :failed,
                result: %{},
                error_code: to_string(reason),
                attempt_count: running.attempt_count
              })
              |> Repo.update!()

            {:error, reason, failed}
        end
      end
    end
  end

  def resolve_stale(%SelectionDecision{} = selection, :pin_old_input) do
    with %StaleRecord{} = record <- latest_stale("selection_decision", selection.id) do
      record
      |> StaleRecord.resolve_changeset(%{
        resolution: :pin_old_input,
        resolved_at: DateTime.utc_now()
      })
      |> Repo.update()
    else
      nil -> {:error, :stale_record_not_found}
    end
  end

  def resolve_stale(%SelectionDecision{} = selection, {:replace, asset_id}) do
    with %StaleRecord{} = record <- latest_stale("selection_decision", selection.id),
         asset <- Assets.get_asset!(asset_id),
         spec_id <- asset.lineage["generation_spec_id"] || selection.generation_spec_id,
         %GenerationSpec{} = spec <- Repo.get(GenerationSpec, spec_id),
         project <- Repo.get!(Project, selection.project_id),
         {:ok, _new_selection} <-
           Quality.select(project, selection.slot_key, spec, asset, note: "stale replacement") do
      record
      |> StaleRecord.resolve_changeset(%{
        resolution: :replaced,
        replacement_asset_id: asset.id,
        resolved_at: DateTime.utc_now()
      })
      |> Repo.update()
    else
      nil -> {:error, :stale_record_not_found}
      _ -> {:error, :replacement_not_selectable}
    end
  end

  def schedule_neighbor_qc(%Project{id: project_id}, ordered_slots, changed_slot) do
    with index when is_integer(index) <- Enum.find_index(ordered_slots, &(&1 == changed_slot)) do
      target_slots = Enum.slice(ordered_slots, max(0, index - 1), min(3, length(ordered_slots)))

      selections =
        Repo.all(
          from selection in SelectionDecision,
            where:
              selection.project_id == ^project_id and selection.status == :active and
                selection.slot_key in ^target_slots
        )
        |> Map.new(&{&1.slot_key, &1})

      jobs =
        target_slots
        |> Enum.flat_map(fn slot ->
          case Map.get(selections, slot) do
            nil ->
              []

            selection ->
              insert_neighbor_stale(project_id, changed_slot, selection)

              {:ok, job} =
                %{
                  "asset_version_id" => selection.asset_version_id,
                  "generation_spec_id" => selection.generation_spec_id
                }
                |> SemanticQCJob.new(
                  schedule_in: 1,
                  unique: [period: 60, fields: [:worker, :args]]
                )
                |> Oban.insert()

              [job]
          end
        end)

      {:ok, jobs}
    else
      nil -> {:error, :changed_slot_not_found}
    end
  end

  defp traverse([], _adjacency, _seen, targets), do: Enum.reverse(targets)

  defp traverse([key | rest], adjacency, seen, targets) do
    {next, seen, targets} =
      adjacency
      |> Map.get(key, [])
      |> Enum.reduce({rest, seen, targets}, fn edge, {queue, visited, collected} ->
        downstream = {edge.downstream_type, edge.downstream_id}

        if MapSet.member?(visited, downstream) do
          {queue, visited, collected}
        else
          target = %{
            type: edge.downstream_type,
            id: edge.downstream_id,
            relation: edge.relation,
            metadata: edge.metadata
          }

          {queue ++ [downstream], MapSet.put(visited, downstream), [target | collected]}
        end
      end)

    traverse(next, adjacency, seen, targets)
  end

  defp action_for(%{type: "generation_spec"}), do: "deterministic_recompile"
  defp action_for(%{type: "node_run"}), do: "cancel_unsubmitted"

  defp action_for(%{type: "attempt", id: id}) do
    case Repo.get(Attempt, id) do
      %Attempt{status: :prepared} ->
        "supersede_unsubmitted"

      %Attempt{status: status} when status in [:submitted, :unknown_remote_state] ->
        "reconcile_submitted"

      _ ->
        "mark_stale"
    end
  end

  defp action_for(_target), do: "mark_stale"

  defp perform_action(%ChangeNode{action: "deterministic_recompile"} = node) do
    {:ok,
     %{
       "compiled_hash" =>
         CanonicalJSON.hash(%{
           "target_id" => node.target_id,
           "new_revision_id" => node.input_snapshot["new_revision_id"],
           "input_hash" => node.input_hash
         })
     }}
  end

  defp perform_action(%ChangeNode{action: "mark_stale"} = node) do
    insert_change_stale(node, "upstream_revision_changed")
  end

  defp perform_action(%ChangeNode{action: "reconcile_submitted"} = node) do
    insert_change_stale(node, "old_input_in_flight")
  end

  defp perform_action(%ChangeNode{action: "supersede_unsubmitted", target_id: id}) do
    case Repo.get(Attempt, id) do
      %Attempt{status: :prepared} = attempt ->
        case Generation.transition_attempt(attempt, :superseded, %{
               error_code: "superseded_by_new_input",
               error_message: "superseded_by_new_input"
             }) do
          {:ok, updated} -> {:ok, %{"attempt_status" => Atom.to_string(updated.status)}}
          {:error, reason} -> {:error, reason}
        end

      %Attempt{} = attempt ->
        {:ok, %{"attempt_status" => Atom.to_string(attempt.status)}}

      nil ->
        {:error, :attempt_not_found}
    end
  end

  defp perform_action(%ChangeNode{action: "cancel_unsubmitted", target_id: id}) do
    case Repo.get(NodeRun, id) do
      %NodeRun{status: status} = node when status in [:blocked, :queued] ->
        case Workflow.transition_node(node, :cancelled) do
          {:ok, updated} -> {:ok, %{"node_status" => Atom.to_string(updated.status)}}
          {:error, reason} -> {:error, reason}
        end

      %NodeRun{} = node ->
        {:ok, %{"node_status" => Atom.to_string(node.status)}}

      nil ->
        {:error, :node_run_not_found}
    end
  end

  defp insert_change_stale(node, reason) do
    change_set = Repo.get!(ChangeSet, node.change_set_id)

    insert_stale(%{
      project_id: change_set.project_id,
      change_set_id: change_set.id,
      subject_type: node.target_type,
      subject_id: node.target_id,
      reason: reason,
      old_input_id: change_set.old_revision_id,
      new_input_id: change_set.new_revision_id,
      idempotency_key: "change:#{change_set.id}:#{node.target_type}:#{node.target_id}:#{reason}"
    })

    {:ok, %{"stale" => true, "reason" => reason}}
  end

  defp insert_neighbor_stale(project_id, changed_slot, selection) do
    insert_stale(%{
      project_id: project_id,
      subject_type: "selection_decision",
      subject_id: selection.id,
      reason: "neighbor_semantic_qc_stale",
      idempotency_key: "neighbor-qc:#{changed_slot}:#{selection.id}:#{selection.asset_version_id}"
    })
  end

  defp insert_stale(attrs) do
    %StaleRecord{}
    |> StaleRecord.create_changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:idempotency_key])
  end

  defp latest_stale(subject_type, subject_id) do
    Repo.one(
      from record in StaleRecord,
        where:
          record.subject_type == ^subject_type and record.subject_id == ^subject_id and
            record.resolution == :unresolved,
        order_by: [desc: record.inserted_at],
        limit: 1
    )
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
