defmodule Dramatizer.Workflow do
  @moduledoc "Recoverable workflow state, inbox deduplication, and transactional outbox events."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Workflow.{InboxMessage, NodeRun, OutboxEvent, WorkflowRun}

  @allowed_transitions %{
    blocked: [:queued, :cancelled, :superseded],
    queued: [:running, :cancelled, :superseded],
    running: [:queued, :succeeded, :failed, :cancelled, :superseded],
    failed: [:queued, :superseded],
    succeeded: [],
    cancelled: [],
    superseded: []
  }

  def create_run(%Project{id: project_id}, definition_key, input_snapshot, idempotency_key) do
    attrs = %{
      project_id: project_id,
      definition_key: definition_key,
      input_snapshot: input_snapshot,
      input_hash: CanonicalJSON.hash(input_snapshot),
      idempotency_key: idempotency_key
    }

    %WorkflowRun{}
    |> WorkflowRun.create_changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :definition_key, :idempotency_key]
    )

    {:ok,
     Repo.get_by!(WorkflowRun,
       project_id: project_id,
       definition_key: definition_key,
       idempotency_key: idempotency_key
     )}
  end

  def add_node(%WorkflowRun{id: workflow_run_id}, node_key, input_snapshot, required_parent_keys) do
    status = if required_parent_keys == [], do: :queued, else: :blocked
    input_hash = CanonicalJSON.hash(input_snapshot)

    attrs = %{
      workflow_run_id: workflow_run_id,
      node_key: node_key,
      status: status,
      input_snapshot: input_snapshot,
      input_hash: input_hash,
      required_parent_keys: required_parent_keys
    }

    %NodeRun{}
    |> NodeRun.create_changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:workflow_run_id, :node_key, :input_hash]
    )

    {:ok,
     Repo.get_by!(NodeRun,
       workflow_run_id: workflow_run_id,
       node_key: node_key,
       input_hash: input_hash
     )}
  end

  def transition_node(node, target, attrs \\ %{})

  def transition_node(%NodeRun{id: id}, target, attrs) do
    Repo.transaction(fn ->
      current = Repo.one!(from node in NodeRun, where: node.id == ^id, lock: "FOR UPDATE")

      case transition_locked(current, target, attrs) do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  @doc false
  def transition_locked(%NodeRun{} = current, target, attrs) do
    if target in Map.fetch!(@allowed_transitions, current.status) do
      values = transition_values(current, target, attrs)

      updated =
        current
        |> NodeRun.transition_changeset(values)
        |> Repo.update!()

      event_attrs = %{
        aggregate_type: "node_run",
        aggregate_id: updated.id,
        event_type: "node_#{target}",
        payload: %{
          "workflow_run_id" => updated.workflow_run_id,
          "node_key" => updated.node_key,
          "status" => Atom.to_string(updated.status),
          "run_count" => updated.run_count
        },
        idempotency_key:
          "node:#{updated.id}:#{target}:#{updated.run_count}:#{updated.lock_version}"
      }

      %OutboxEvent{}
      |> OutboxEvent.create_changeset(event_attrs)
      |> Repo.insert!()

      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  def retry_node(%NodeRun{status: :failed} = node) do
    transition_node(node, :queued, %{
      run_count: node.run_count + 1,
      error_code: nil,
      result: %{},
      active_job_id: nil,
      lease_expires_at: nil,
      next_retry_at: nil,
      started_at: nil,
      completed_at: nil
    })
  end

  def retry_node(%NodeRun{}), do: {:error, :node_not_failed}

  def queue_ready_nodes(workflow_run_id) do
    blocked =
      Repo.all(
        from node in NodeRun,
          where: node.workflow_run_id == ^workflow_run_id and node.status == :blocked
      )

    Enum.flat_map(blocked, fn node ->
      parents =
        Repo.all(
          from parent in NodeRun,
            where:
              parent.workflow_run_id == ^workflow_run_id and
                parent.node_key in ^node.required_parent_keys,
            select: {parent.node_key, parent.status}
        )
        |> Map.new()

      ready? =
        Enum.all?(node.required_parent_keys, fn key -> Map.get(parents, key) == :succeeded end)

      if ready? do
        case transition_node(node, :queued) do
          {:ok, queued} -> [queued]
          _ -> []
        end
      else
        []
      end
    end)
  end

  def record_inbox(provider, external_id, payload) do
    attrs = %{
      provider: provider,
      external_id: external_id,
      payload: payload,
      received_at: DateTime.utc_now()
    }

    result =
      %InboxMessage{}
      |> InboxMessage.create_changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:provider, :external_id])

    case result do
      {:ok, inserted} ->
        stored = Repo.get_by!(InboxMessage, provider: provider, external_id: external_id)
        disposition = if inserted.id == stored.id, do: :inserted, else: :duplicate
        {:ok, stored, disposition}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_node!(id), do: Repo.get!(NodeRun, id)

  def mark_run(%WorkflowRun{} = run, status)
      when status in [:running, :succeeded, :failed, :cancelled, :superseded] do
    now = DateTime.utc_now()

    attrs =
      case status do
        :running -> %{status: status, started_at: run.started_at || now, completed_at: nil}
        _ -> %{status: status, completed_at: now}
      end

    run |> WorkflowRun.status_changeset(attrs) |> Repo.update()
  end

  defp transition_values(node, target, attrs) do
    now = DateTime.utc_now()

    defaults =
      case target do
        :running ->
          %{
            status: target,
            started_at: node.started_at || now,
            completed_at: nil,
            next_retry_at: nil
          }

        status when status in [:succeeded, :failed, :cancelled, :superseded] ->
          %{
            status: target,
            completed_at: now,
            active_job_id: nil,
            lease_expires_at: nil,
            next_retry_at: nil
          }

        _ ->
          %{status: target}
      end

    Map.merge(defaults, Map.new(attrs))
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
