defmodule Dramatizer.Repo.Migrations.CreateQualityTables do
  use Ecto.Migration

  def up do
    create table(:quality_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :asset_version_id, references(:asset_versions, type: :binary_id, on_delete: :restrict),
        null: false

      add :generation_spec_id,
          references(:generation_specs, type: :binary_id, on_delete: :restrict), null: false

      add :kind, :text, null: false
      add :status, :text, null: false
      add :blocking, :boolean, null: false, default: false
      add :evidence, :map, null: false
      add :input_hash, :text, null: false

      add :evaluator_request_snapshot_id,
          references(:provider_request_snapshots, type: :binary_id, on_delete: :restrict)

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:quality_reports, [:asset_version_id, :kind, :input_hash])
    create index(:quality_reports, [:generation_spec_id, :kind, :status])

    create constraint(:quality_reports, :quality_kind_check,
             check: "kind IN ('technical', 'semantic')"
           )

    create constraint(:quality_reports, :quality_status_check,
             check: "status IN ('pass', 'fail', 'warning', 'inconclusive', 'evaluator_failed')"
           )

    create table(:selection_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :slot_key, :text, null: false

      add :generation_spec_id,
          references(:generation_specs, type: :binary_id, on_delete: :restrict), null: false

      add :asset_version_id, references(:asset_versions, type: :binary_id, on_delete: :restrict),
        null: false

      add :status, :text, null: false, default: "active"
      add :accepted_semantic_failure, :boolean, null: false, default: false
      add :note, :text
      add :decided_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:selection_decisions, [:project_id, :slot_key],
             where: "status = 'active'",
             name: :selection_decisions_one_active_slot
           )

    create index(:selection_decisions, [:asset_version_id])

    create constraint(:selection_decisions, :selection_status_check,
             check: "status IN ('active', 'superseded')"
           )

    execute "CREATE TRIGGER quality_reports_immutable BEFORE UPDATE OR DELETE ON quality_reports FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS quality_reports_immutable ON quality_reports"
    drop table(:selection_decisions)
    drop table(:quality_reports)
  end
end
