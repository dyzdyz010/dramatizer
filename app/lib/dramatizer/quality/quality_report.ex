defmodule Dramatizer.Quality.QualityReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "quality_reports" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :asset_version, Dramatizer.Assets.AssetVersion
    belongs_to :generation_spec, Dramatizer.Generation.GenerationSpec
    field :kind, Ecto.Enum, values: [:technical, :semantic]
    field :status, Ecto.Enum, values: [:pass, :fail, :warning, :inconclusive, :evaluator_failed]
    field :blocking, :boolean, default: false
    field :evidence, :map
    field :input_hash, :string
    belongs_to :evaluator_request_snapshot, Dramatizer.Generation.ProviderRequestSnapshot

    timestamps()
  end

  def create_changeset(report, attrs) do
    report
    |> cast(attrs, [
      :project_id,
      :asset_version_id,
      :generation_spec_id,
      :kind,
      :status,
      :blocking,
      :evidence,
      :input_hash,
      :evaluator_request_snapshot_id
    ])
    |> validate_required([
      :project_id,
      :asset_version_id,
      :generation_spec_id,
      :kind,
      :status,
      :blocking,
      :evidence,
      :input_hash
    ])
    |> unique_constraint([:asset_version_id, :kind, :input_hash])
  end
end
