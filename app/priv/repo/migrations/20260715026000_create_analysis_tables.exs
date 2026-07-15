defmodule Dramatizer.Repo.Migrations.CreateAnalysisTables do
  use Ecto.Migration

  def up do
    create table(:analysis_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :workflow_run_id, references(:workflow_runs, type: :binary_id, on_delete: :restrict),
        null: false

      add :source_revision_ids, {:array, :binary_id}, null: false
      add :task_snapshot_ids, {:array, :binary_id}, null: false
      add :node_results, :map, null: false
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:analysis_snapshots, [:workflow_run_id])
    create index(:analysis_snapshots, [:project_id])

    execute "CREATE TRIGGER analysis_snapshots_immutable BEFORE UPDATE OR DELETE ON analysis_snapshots FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS analysis_snapshots_immutable ON analysis_snapshots"
    drop table(:analysis_snapshots)
  end
end
