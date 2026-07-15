defmodule Dramatizer.Timeline.RenderManifest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "render_manifests" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :timeline, Dramatizer.Timeline.Timeline
    belongs_to :timeline_version, Dramatizer.Timeline.TimelineVersion
    field :render_mode, Ecto.Enum, values: [:preview, :formal]

    field :status, Ecto.Enum,
      values: [:prepared, :rendering, :rendered, :failed],
      default: :prepared

    field :width, :integer
    field :height, :integer
    field :fps, :integer
    field :duration_ms, :integer
    field :input_manifest, :map
    field :recipe_hash, :string
    belongs_to :output_asset, Dramatizer.Assets.AssetVersion
    belongs_to :srt_asset, Dramatizer.Assets.AssetVersion
    field :technical_qc, :map, default: %{}
    field :error_code, :string

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [
      :project_id,
      :timeline_id,
      :timeline_version_id,
      :render_mode,
      :width,
      :height,
      :fps,
      :duration_ms,
      :input_manifest,
      :recipe_hash
    ])
    |> validate_required([
      :project_id,
      :timeline_id,
      :render_mode,
      :width,
      :height,
      :fps,
      :duration_ms,
      :input_manifest,
      :recipe_hash
    ])
    |> unique_constraint([:project_id, :render_mode, :recipe_hash])
  end

  def status_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [:status, :output_asset_id, :srt_asset_id, :technical_qc, :error_code])
    |> validate_required([:status, :technical_qc])
  end
end
