defmodule Dramatizer.Repo.Migrations.CreateWorkflowGenerationCostTables do
  use Ecto.Migration

  def up do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :definition_key, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :input_snapshot, :map, null: false
      add :input_hash, :text, null: false
      add :graph_epoch, :integer, null: false, default: 1
      add :idempotency_key, :text, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflow_runs, [:project_id, :definition_key, :idempotency_key])
    create index(:workflow_runs, [:project_id, :status])

    create constraint(:workflow_runs, :workflow_run_status_check,
             check:
               "status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled', 'superseded')"
           )

    create table(:node_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :node_key, :text, null: false
      add :status, :text, null: false
      add :input_snapshot, :map, null: false
      add :input_hash, :text, null: false
      add :required_parent_keys, {:array, :text}, null: false, default: []
      add :run_count, :integer, null: false, default: 1
      add :result, :map, null: false, default: %{}
      add :error_code, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_runs, [:workflow_run_id, :node_key, :input_hash])
    create index(:node_runs, [:workflow_run_id, :status])

    create constraint(:node_runs, :node_run_status_check,
             check:
               "status IN ('blocked', 'queued', 'running', 'succeeded', 'failed', 'cancelled', 'superseded')"
           )

    create table(:inbox_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :text, null: false
      add :external_id, :text, null: false
      add :payload, :map, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
    end

    create unique_index(:inbox_messages, [:provider, :external_id])

    create table(:outbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :aggregate_type, :text, null: false
      add :aggregate_id, :binary_id, null: false
      add :event_type, :text, null: false
      add :payload, :map, null: false
      add :status, :text, null: false, default: "pending"
      add :idempotency_key, :text, null: false
      add :published_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:outbox_events, [:idempotency_key])
    create index(:outbox_events, [:status, :inserted_at])

    create table(:generation_specs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :revision_id, references(:revisions, type: :binary_id, on_delete: :restrict)
      add :kind, :text, null: false
      add :candidate_index, :integer, null: false, default: 0
      add :formal, :boolean, null: false, default: true
      add :payload, :map, null: false
      add :payload_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:generation_specs, [
             :project_id,
             :kind,
             :payload_hash,
             :candidate_index,
             :formal
           ])

    create table(:provider_request_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :generation_spec_id,
          references(:generation_specs, type: :binary_id, on_delete: :restrict), null: false

      add :node_run_id, references(:node_runs, type: :binary_id, on_delete: :restrict)
      add :task_type, :text, null: false
      add :adapter, :text, null: false
      add :credential_ref, :text, null: false
      add :model, :text, null: false
      add :params, :map, null: false, default: %{}
      add :request_input, :map, null: false
      add :prompt_snapshot, :map, null: false, default: %{}
      add :request_hash, :text, null: false
      add :secrets_excluded, :boolean, null: false, default: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:provider_request_snapshots, [:generation_spec_id, :request_hash])

    create table(:attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_request_snapshot_id,
          references(:provider_request_snapshots, type: :binary_id, on_delete: :restrict),
          null: false

      add :node_run_id, references(:node_runs, type: :binary_id, on_delete: :restrict)
      add :attempt_number, :integer, null: false
      add :status, :text, null: false, default: "prepared"
      add :idempotency_key, :text, null: false
      add :external_request_id, :text
      add :result_asset_id, references(:asset_versions, type: :binary_id, on_delete: :restrict)
      add :response_metadata, :map, null: false, default: %{}
      add :error_code, :text
      add :error_message, :text
      add :submitted_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attempts, [:provider_request_snapshot_id, :attempt_number])
    create unique_index(:attempts, [:idempotency_key])

    create constraint(:attempts, :attempt_status_check,
             check:
               "status IN ('prepared', 'submitted', 'succeeded', 'failed', 'timed_out', 'unknown_remote_state')"
           )

    create table(:project_budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :limit_micros, :bigint
      add :reserved_micros, :bigint, null: false, default: 0
      add :actual_micros, :bigint, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:project_budgets, [:project_id])

    create constraint(:project_budgets, :budget_non_negative,
             check:
               "(limit_micros IS NULL OR limit_micros >= 0) AND reserved_micros >= 0 AND actual_micros >= 0"
           )

    create table(:cost_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :attempt_id, references(:attempts, type: :binary_id, on_delete: :restrict)
      add :entry_type, :text, null: false
      add :amount_micros, :bigint
      add :currency, :text, null: false, default: "USD"
      add :idempotency_key, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:cost_entries, [:idempotency_key])
    create index(:cost_entries, [:project_id, :entry_type])

    create constraint(:cost_entries, :cost_entry_type_check,
             check: "entry_type IN ('estimate', 'reservation', 'actual')"
           )

    execute "CREATE TRIGGER generation_specs_immutable BEFORE UPDATE OR DELETE ON generation_specs FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"

    execute "CREATE TRIGGER provider_request_snapshots_immutable BEFORE UPDATE OR DELETE ON provider_request_snapshots FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"

    execute "CREATE TRIGGER cost_entries_immutable BEFORE UPDATE OR DELETE ON cost_entries FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS cost_entries_immutable ON cost_entries"

    execute "DROP TRIGGER IF EXISTS provider_request_snapshots_immutable ON provider_request_snapshots"

    execute "DROP TRIGGER IF EXISTS generation_specs_immutable ON generation_specs"
    drop table(:cost_entries)
    drop table(:project_budgets)
    drop table(:attempts)
    drop table(:provider_request_snapshots)
    drop table(:generation_specs)
    drop table(:outbox_events)
    drop table(:inbox_messages)
    drop table(:node_runs)
    drop table(:workflow_runs)
  end
end
