defmodule Dramatizer.Timeline.Timeline do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "timelines" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :narrative_revision, Dramatizer.Revisions.Revision
    belongs_to :shot_plan_revision, Dramatizer.Revisions.Revision
    field :profile_snapshot, :map
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(timeline, attrs) do
    timeline
    |> cast(attrs, [
      :project_id,
      :narrative_revision_id,
      :shot_plan_revision_id,
      :profile_snapshot
    ])
    |> validate_required([
      :project_id,
      :narrative_revision_id,
      :shot_plan_revision_id,
      :profile_snapshot
    ])
  end
end
