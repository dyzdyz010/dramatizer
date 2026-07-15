defmodule Dramatizer.Workflow.WorkflowRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_runs" do
    belongs_to :project, Dramatizer.Projects.Project
    field :definition_key, :string

    field :status, Ecto.Enum,
      values: [:pending, :running, :succeeded, :failed, :cancelled, :superseded],
      default: :pending

    field :input_snapshot, :map
    field :input_hash, :string
    field :graph_epoch, :integer, default: 1
    field :idempotency_key, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [:project_id, :definition_key, :input_snapshot, :input_hash, :idempotency_key])
    |> validate_required([
      :project_id,
      :definition_key,
      :input_snapshot,
      :input_hash,
      :idempotency_key
    ])
    |> unique_constraint([:project_id, :definition_key, :idempotency_key])
  end
end
