defmodule Dramatizer.Repo.Migrations.CreateAssetTables do
  use Ecto.Migration

  def up do
    create table(:upload_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :purpose, :text, null: false
      add :status, :text, null: false, default: "staging"
      add :staging_path, :text, null: false
      add :expected_mime, :text
      add :byte_size, :bigint
      add :sha256, :text
      add :idempotency_key, :text, null: false
      add :error_code, :text
      add :finalized_asset_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:upload_intents, [:project_id, :idempotency_key])

    create constraint(:upload_intents, :upload_intent_status_check,
             check: "status IN ('staging', 'failed', 'finalized')"
           )

    create table(:asset_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :upload_intent_id, references(:upload_intents, type: :binary_id, on_delete: :restrict),
        null: false

      add :kind, :text, null: false
      add :source, :text, null: false
      add :parent_asset_id, references(:asset_versions, type: :binary_id, on_delete: :restrict)
      add :blob_hash, :text, null: false
      add :relative_path, :text, null: false
      add :mime_type, :text, null: false
      add :byte_size, :bigint, null: false
      add :width, :integer
      add :height, :integer
      add :duration_ms, :bigint
      add :metadata, :map, null: false, default: %{}
      add :lineage, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:asset_versions, [:upload_intent_id])
    create index(:asset_versions, [:project_id, :kind])
    create index(:asset_versions, [:blob_hash])

    create constraint(:asset_versions, :asset_byte_size_positive, check: "byte_size > 0")

    execute "CREATE TRIGGER asset_versions_immutable BEFORE UPDATE OR DELETE ON asset_versions FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS asset_versions_immutable ON asset_versions"
    drop table(:asset_versions)
    drop table(:upload_intents)
  end
end
