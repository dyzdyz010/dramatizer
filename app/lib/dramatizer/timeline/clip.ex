defmodule Dramatizer.Timeline.Clip do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @motions [:static, :push_in, :pull_out, :pan_left, :pan_right, :pan_up, :pan_down]

  schema "timeline_clips" do
    belongs_to :timeline, Dramatizer.Timeline.Timeline
    field :position, :integer
    field :shot_id, :string
    belongs_to :selection_decision, Dramatizer.Quality.SelectionDecision
    belongs_to :asset_version, Dramatizer.Assets.AssetVersion
    field :placeholder, :boolean, default: true
    field :minimum_duration_ms, :integer
    field :preferred_duration_ms, :integer
    field :maximum_duration_ms, :integer
    field :duration_ms, :integer
    field :duration_warning, :boolean, default: false
    field :motion, Ecto.Enum, values: @motions, default: :static
    field :transition_after, Ecto.Enum, values: [:hard_cut, :cross_dissolve], default: :hard_cut
    field :transition_duration_ms, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def motions, do: @motions

  def create_changeset(clip, attrs) do
    clip
    |> cast(attrs, [
      :timeline_id,
      :position,
      :shot_id,
      :selection_decision_id,
      :asset_version_id,
      :placeholder,
      :minimum_duration_ms,
      :preferred_duration_ms,
      :maximum_duration_ms,
      :duration_ms,
      :duration_warning,
      :motion,
      :transition_after,
      :transition_duration_ms
    ])
    |> validate_required([
      :timeline_id,
      :position,
      :shot_id,
      :placeholder,
      :minimum_duration_ms,
      :preferred_duration_ms,
      :maximum_duration_ms,
      :duration_ms,
      :duration_warning,
      :motion,
      :transition_after,
      :transition_duration_ms
    ])
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:duration_ms, greater_than: 0)
  end

  def edit_changeset(clip, attrs) do
    clip
    |> cast(attrs, [
      :position,
      :selection_decision_id,
      :asset_version_id,
      :placeholder,
      :duration_ms,
      :duration_warning,
      :motion,
      :transition_after,
      :transition_duration_ms
    ])
    |> validate_required([
      :position,
      :placeholder,
      :duration_ms,
      :duration_warning,
      :motion,
      :transition_after,
      :transition_duration_ms
    ])
  end
end
