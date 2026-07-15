defmodule Dramatizer.Projects.ProductionProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @fields ~w(aspect_width aspect_height duration_min_seconds duration_max_seconds shot_min shot_max preview_width preview_height formal_width formal_height)a

  schema "production_profiles" do
    belongs_to :project, Dramatizer.Projects.Project
    field :aspect_width, :integer, default: 9
    field :aspect_height, :integer, default: 16
    field :duration_min_seconds, :integer, default: 60
    field :duration_max_seconds, :integer, default: 120
    field :shot_min, :integer, default: 10
    field :shot_max, :integer, default: 30
    field :preview_width, :integer, default: 540
    field :preview_height, :integer, default: 960
    field :formal_width, :integer, default: 1080
    field :formal_height, :integer, default: 1920

    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:project_id | @fields])
    |> validate_required([:project_id | @fields])
    |> validate_number(:aspect_width, greater_than: 0)
    |> validate_number(:aspect_height, greater_than: 0)
    |> validate_number(:duration_min_seconds, greater_than: 0)
    |> validate_number(:shot_min, greater_than: 0)
    |> validate_ranges()
    |> unique_constraint(:project_id)
    |> check_constraint(:aspect_width, name: :production_profile_positive_check)
  end

  def snapshot(profile_or_map) do
    Map.take(profile_or_map, @fields)
  end

  defp validate_ranges(changeset) do
    min_duration = get_field(changeset, :duration_min_seconds)
    max_duration = get_field(changeset, :duration_max_seconds)
    min_shots = get_field(changeset, :shot_min)
    max_shots = get_field(changeset, :shot_max)

    changeset
    |> maybe_error(
      :duration_max_seconds,
      max_duration < min_duration,
      "must be at least the minimum"
    )
    |> maybe_error(:shot_max, max_shots < min_shots, "must be at least the minimum")
  end

  defp maybe_error(changeset, field, true, message), do: add_error(changeset, field, message)
  defp maybe_error(changeset, _field, false, _message), do: changeset
end
