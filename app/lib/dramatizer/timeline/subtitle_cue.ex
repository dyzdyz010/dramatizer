defmodule Dramatizer.Timeline.SubtitleCue do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subtitle_cues" do
    belongs_to :timeline, Dramatizer.Timeline.Timeline
    field :position, :integer
    field :text, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :style, :map
    belongs_to :narrative_revision, Dramatizer.Revisions.Revision
    field :source_event_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(cue, attrs) do
    cue
    |> cast(attrs, [
      :timeline_id,
      :position,
      :text,
      :start_ms,
      :end_ms,
      :style,
      :narrative_revision_id,
      :source_event_id
    ])
    |> validate_required([
      :timeline_id,
      :position,
      :text,
      :start_ms,
      :end_ms,
      :style,
      :narrative_revision_id,
      :source_event_id
    ])
    |> validate_timing()
  end

  def edit_changeset(cue, attrs) do
    cue
    |> cast(attrs, [:text, :start_ms, :end_ms, :style])
    |> validate_required([:text, :start_ms, :end_ms, :style])
    |> validate_timing()
  end

  defp validate_timing(changeset) do
    start_ms = get_field(changeset, :start_ms)
    end_ms = get_field(changeset, :end_ms)

    if is_integer(start_ms) and is_integer(end_ms) and end_ms > start_ms and start_ms >= 0,
      do: changeset,
      else: add_error(changeset, :end_ms, "must be after start")
  end
end
