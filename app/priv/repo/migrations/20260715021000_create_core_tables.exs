defmodule Dramatizer.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:projects, :projects_status_check,
             check: "status IN ('active', 'archived')"
           )

    create table(:production_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :aspect_width, :integer, null: false, default: 9
      add :aspect_height, :integer, null: false, default: 16
      add :duration_min_seconds, :integer, null: false, default: 60
      add :duration_max_seconds, :integer, null: false, default: 120
      add :shot_min, :integer, null: false, default: 10
      add :shot_max, :integer, null: false, default: 30
      add :preview_width, :integer, null: false, default: 540
      add :preview_height, :integer, null: false, default: 960
      add :formal_width, :integer, null: false, default: 1080
      add :formal_height, :integer, null: false, default: 1920

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:production_profiles, [:project_id])

    create constraint(:production_profiles, :production_profile_positive_check,
             check:
               "aspect_width > 0 AND aspect_height > 0 AND duration_min_seconds > 0 AND duration_max_seconds >= duration_min_seconds AND shot_min > 0 AND shot_max >= shot_min AND preview_width > 0 AND preview_height > 0 AND formal_width > 0 AND formal_height > 0"
           )

    create table(:model_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_type, :text, null: false
      add :adapter, :text
      add :credential_ref, :text
      add :model, :text
      add :params, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:model_overrides, [:project_id, :task_type])

    create table(:prompt_appendices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_type, :text, null: false
      add :revision, :integer, null: false
      add :body, :text, null: false, default: ""
      add :body_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:prompt_appendices, [:project_id, :task_type, :revision])

    create constraint(:prompt_appendices, :prompt_appendix_revision_positive,
             check: "revision > 0"
           )

    create table(:revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :logical_id, :binary_id, null: false
      add :kind, :text, null: false
      add :revision, :integer, null: false
      add :parent_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict)
      add :draft_id, :binary_id, null: false
      add :payload, :map, null: false
      add :provenance, :map, null: false, default: %{}
      add :profile_snapshot, :map, null: false
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:revisions, [:logical_id, :revision])
    create unique_index(:revisions, [:draft_id])
    create index(:revisions, [:project_id, :kind])
    create constraint(:revisions, :revision_positive, check: "revision > 0")

    create table(:drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :logical_id, :binary_id, null: false
      add :kind, :text, null: false
      add :status, :text, null: false, default: "editing"
      add :base_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict)
      add :confirmed_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict)
      add :payload, :map, null: false
      add :provenance, :map, null: false, default: %{}
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:drafts, [:project_id, :kind, :status])

    create unique_index(:drafts, [:confirmed_revision_id],
             where: "confirmed_revision_id IS NOT NULL"
           )

    create constraint(:drafts, :draft_status_check, check: "status IN ('editing', 'confirmed')")

    execute """
    CREATE FUNCTION prevent_dramatizer_immutable_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'immutable_record';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute "CREATE TRIGGER revisions_immutable BEFORE UPDATE OR DELETE ON revisions FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"

    execute "CREATE TRIGGER prompt_appendices_immutable BEFORE UPDATE OR DELETE ON prompt_appendices FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS prompt_appendices_immutable ON prompt_appendices"
    execute "DROP TRIGGER IF EXISTS revisions_immutable ON revisions"
    execute "DROP FUNCTION IF EXISTS prevent_dramatizer_immutable_mutation()"
    drop table(:drafts)
    drop table(:revisions)
    drop table(:prompt_appendices)
    drop table(:model_overrides)
    drop table(:production_profiles)
    drop table(:projects)
  end
end
