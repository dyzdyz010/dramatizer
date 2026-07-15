defmodule Dramatizer.Analysis.AnalysisSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "analysis_snapshots" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :workflow_run, Dramatizer.Workflow.WorkflowRun
    field :source_revision_ids, {:array, Ecto.UUID}
    field :task_snapshot_ids, {:array, Ecto.UUID}
    field :node_results, :map
    field :content_hash, :string

    timestamps()
  end

  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :project_id,
      :workflow_run_id,
      :source_revision_ids,
      :task_snapshot_ids,
      :node_results,
      :content_hash
    ])
    |> validate_required([
      :project_id,
      :workflow_run_id,
      :source_revision_ids,
      :task_snapshot_ids,
      :node_results,
      :content_hash
    ])
    |> unique_constraint(:workflow_run_id)
  end
end
