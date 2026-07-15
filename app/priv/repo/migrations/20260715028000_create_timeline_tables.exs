defmodule Dramatizer.Repo.Migrations.CreateTimelineTables do
  use Ecto.Migration

  def up do
    create table(:timelines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :narrative_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :shot_plan_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :profile_snapshot, :map, null: false
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create table(:timeline_clips, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :timeline_id, references(:timelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :shot_id, :text, null: false

      add :selection_decision_id,
          references(:selection_decisions, type: :binary_id, on_delete: :restrict)

      add :asset_version_id, references(:asset_versions, type: :binary_id, on_delete: :restrict)
      add :placeholder, :boolean, null: false, default: true
      add :minimum_duration_ms, :integer, null: false
      add :preferred_duration_ms, :integer, null: false
      add :maximum_duration_ms, :integer, null: false
      add :duration_ms, :integer, null: false
      add :duration_warning, :boolean, null: false, default: false
      add :motion, :text, null: false, default: "static"
      add :transition_after, :text, null: false, default: "hard_cut"
      add :transition_duration_ms, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:timeline_clips, [:timeline_id, :position])

    create constraint(:timeline_clips, :timeline_clip_motion_check,
             check:
               "motion IN ('static', 'push_in', 'pull_out', 'pan_left', 'pan_right', 'pan_up', 'pan_down')"
           )

    create constraint(:timeline_clips, :timeline_clip_transition_check,
             check: "transition_after IN ('hard_cut', 'cross_dissolve')"
           )

    create constraint(:timeline_clips, :timeline_clip_duration_check,
             check:
               "minimum_duration_ms > 0 AND preferred_duration_ms > 0 AND maximum_duration_ms > 0 AND duration_ms > 0 AND transition_duration_ms >= 0"
           )

    create table(:subtitle_cues, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :timeline_id, references(:timelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :text, :text, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer, null: false
      add :style, :map, null: false

      add :narrative_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :source_event_id, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subtitle_cues, [:timeline_id, :position])

    create constraint(:subtitle_cues, :subtitle_timing_check,
             check: "start_ms >= 0 AND end_ms > start_ms"
           )

    create table(:timeline_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :timeline_id, references(:timelines, type: :binary_id, on_delete: :restrict),
        null: false

      add :version, :integer, null: false

      add :narrative_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :shot_plan_revision_id, references(:revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :profile_snapshot, :map, null: false
      add :clip_snapshot, {:array, :map}, null: false
      add :subtitle_snapshot, {:array, :map}, null: false
      add :duration_ms, :integer, null: false
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:timeline_versions, [:timeline_id, :version])

    create table(:render_manifests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :timeline_id, references(:timelines, type: :binary_id, on_delete: :restrict),
        null: false

      add :timeline_version_id,
          references(:timeline_versions, type: :binary_id, on_delete: :restrict)

      add :render_mode, :text, null: false
      add :status, :text, null: false, default: "prepared"
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :fps, :integer, null: false
      add :duration_ms, :integer, null: false
      add :input_manifest, :map, null: false
      add :recipe_hash, :text, null: false
      add :output_asset_id, references(:asset_versions, type: :binary_id, on_delete: :restrict)
      add :srt_asset_id, references(:asset_versions, type: :binary_id, on_delete: :restrict)
      add :technical_qc, :map, null: false, default: %{}
      add :error_code, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:render_manifests, [:project_id, :render_mode, :recipe_hash])

    create constraint(:render_manifests, :render_mode_check,
             check: "render_mode IN ('preview', 'formal')"
           )

    create constraint(:render_manifests, :render_status_check,
             check: "status IN ('prepared', 'rendering', 'rendered', 'failed')"
           )

    execute "CREATE TRIGGER timeline_versions_immutable BEFORE UPDATE OR DELETE ON timeline_versions FOR EACH ROW EXECUTE FUNCTION prevent_dramatizer_immutable_mutation()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS timeline_versions_immutable ON timeline_versions"
    drop table(:render_manifests)
    drop table(:timeline_versions)
    drop table(:subtitle_cues)
    drop table(:timeline_clips)
    drop table(:timelines)
  end
end
