defmodule Dramatizer.Repo.Migrations.CreateSourceTables do
  use Ecto.Migration

  def up do
    create table(:source_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :role, :text, null: false
      add :name, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:source_documents, [:project_id, :role])

    create constraint(:source_documents, :source_document_role_check,
             check: "role IN ('volume', 'companion')"
           )

    create table(:source_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :source_document_id,
          references(:source_documents, type: :binary_id, on_delete: :restrict),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :revision, :integer, null: false

      add :parent_revision_id,
          references(:source_revisions, type: :binary_id, on_delete: :restrict)

      add :asset_version_id, references(:asset_versions, type: :binary_id, on_delete: :restrict),
        null: false

      add :source_format, :text, null: false
      add :original_filename, :text, null: false
      add :parser_version, :text, null: false
      add :content_hash, :text, null: false
      add :character_count, :bigint, null: false
      add :byte_count, :bigint, null: false
      add :locators, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:source_revisions, [:source_document_id, :revision])
    create index(:source_revisions, [:project_id])
    create index(:source_revisions, [:asset_version_id])

    create constraint(:source_revisions, :source_revision_positive,
             check: "revision > 0 AND character_count > 0 AND byte_count > 0"
           )

    create constraint(:source_revisions, :source_format_check,
             check: "source_format IN ('text', 'markdown', 'pdf')"
           )

    execute "CREATE TRIGGER source_revisions_immutable BEFORE UPDATE OR DELETE ON source_revisions FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS source_revisions_immutable ON source_revisions"
    drop table(:source_revisions)
    drop table(:source_documents)
  end
end
