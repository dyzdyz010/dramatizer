defmodule Dramatizer.Workflow.NodeRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses [:blocked, :queued, :running, :succeeded, :failed, :cancelled, :superseded]

  schema "node_runs" do
    belongs_to :workflow_run, Dramatizer.Workflow.WorkflowRun
    field :node_key, :string
    field :status, Ecto.Enum, values: @statuses
    field :input_snapshot, :map
    field :input_hash, :string
    field :required_parent_keys, {:array, :string}, default: []
    field :run_count, :integer, default: 1
    field :result, :map, default: %{}
    field :error_code, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :workflow_run_id,
      :node_key,
      :status,
      :input_snapshot,
      :input_hash,
      :required_parent_keys
    ])
    |> validate_required([
      :workflow_run_id,
      :node_key,
      :status,
      :input_snapshot,
      :input_hash,
      :required_parent_keys
    ])
    |> unique_constraint([:workflow_run_id, :node_key, :input_hash])
  end

  def transition_changeset(node, attrs) do
    node
    |> cast(attrs, [:status, :result, :error_code, :started_at, :completed_at, :run_count])
    |> validate_required([:status, :result, :run_count])
    |> optimistic_lock(:lock_version)
  end
end
