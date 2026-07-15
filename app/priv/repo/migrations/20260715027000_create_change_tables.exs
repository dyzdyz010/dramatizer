defmodule Dramatizer.Repo.Migrations.CreateChangeTables do
  use Ecto.Migration

  def up do
    drop constraint(:attempts, :attempt_status_check)

    create constraint(:attempts, :attempt_status_check,
             check:
               "status IN ('prepared', 'submitted', 'succeeded', 'failed', 'timed_out', 'unknown_remote_state', 'superseded')"
           )

    create table(:dependency_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :upstream_type, :text, null: false
      add :upstream_id, :binary_id, null: false
      add :downstream_type, :text, null: false
      add :downstream_id, :binary_id, null: false
      add :relation, :text, null: false, default: "depends_on"
      add :graph_epoch, :integer, null: false, default: 1
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(
             :dependency_edges,
             [
               :project_id,
               :upstream_type,
               :upstream_id,
               :downstream_type,
               :downstream_id,
               :graph_epoch
             ],
             name: :dependency_edges_exact_unique
           )

    create index(:dependency_edges, [:project_id, :upstream_type, :upstream_id])

    create table(:change_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :old_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :new_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :status, :text, null: false, default: "confirmed"
      add :diff, :map, null: false
      add :graph_epoch, :integer, null: false
      add :selected_target_ids, {:array, :binary_id}, null: false
      add :actions, :map, null: false
      add :idempotency_key, :text, null: false
      add :confirmed_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_sets, [:idempotency_key])

    create constraint(:change_sets, :change_set_status_check,
             check: "status IN ('confirmed', 'running', 'succeeded', 'partial_failed')"
           )

    create table(:change_nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_set_id, references(:change_sets, type: :binary_id, on_delete: :restrict),
        null: false

      add :node_key, :text, null: false
      add :target_type, :text, null: false
      add :target_id, :binary_id, null: false
      add :action, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :input_snapshot, :map, null: false
      add :input_hash, :text, null: false
      add :result, :map, null: false, default: %{}
      add :error_code, :text
      add :attempt_count, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_nodes, [:change_set_id, :node_key])

    create constraint(:change_nodes, :change_node_status_check,
             check: "status IN ('pending', 'running', 'succeeded', 'failed')"
           )

    create table(:stale_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :change_set_id, references(:change_sets, type: :binary_id, on_delete: :restrict)
      add :subject_type, :text, null: false
      add :subject_id, :binary_id, null: false
      add :reason, :text, null: false
      add :old_input_id, :binary_id
      add :new_input_id, :binary_id
      add :resolution, :text, null: false, default: "unresolved"

      add :replacement_asset_id,
          references(:asset_versions, type: :binary_id, on_delete: :restrict)

      add :idempotency_key, :text, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stale_records, [:idempotency_key])
    create index(:stale_records, [:subject_type, :subject_id, :resolution])

    create constraint(:stale_records, :stale_resolution_check,
             check: "resolution IN ('unresolved', 'pin_old_input', 'replaced')"
           )

    execute "CREATE TRIGGER dependency_edges_immutable BEFORE UPDATE OR DELETE ON dependency_edges FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS dependency_edges_immutable ON dependency_edges"
    drop table(:stale_records)
    drop table(:change_nodes)
    drop table(:change_sets)
    drop table(:dependency_edges)

    drop constraint(:attempts, :attempt_status_check)

    create constraint(:attempts, :attempt_status_check,
             check:
               "status IN ('prepared', 'submitted', 'succeeded', 'failed', 'timed_out', 'unknown_remote_state')"
           )
  end
end
