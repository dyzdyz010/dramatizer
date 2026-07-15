defmodule Dramatizer.Timeline.TimelineVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "timeline_versions" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :timeline, Dramatizer.Timeline.Timeline
    field :version, :integer
    belongs_to :narrative_revision, Dramatizer.Revisions.Revision
    belongs_to :shot_plan_revision, Dramatizer.Revisions.Revision
    field :profile_snapshot, :map
    field :clip_snapshot, {:array, :map}
    field :subtitle_snapshot, {:array, :map}
    field :duration_ms, :integer
    field :content_hash, :string

    timestamps()
  end

  def create_changeset(version, attrs) do
    version
    |> cast(attrs, [
      :project_id,
      :timeline_id,
      :version,
      :narrative_revision_id,
      :shot_plan_revision_id,
      :profile_snapshot,
      :clip_snapshot,
      :subtitle_snapshot,
      :duration_ms,
      :content_hash
    ])
    |> validate_required([
      :project_id,
      :timeline_id,
      :version,
      :narrative_revision_id,
      :shot_plan_revision_id,
      :profile_snapshot,
      :clip_snapshot,
      :subtitle_snapshot,
      :duration_ms,
      :content_hash
    ])
    |> unique_constraint([:timeline_id, :version])
  end
end
