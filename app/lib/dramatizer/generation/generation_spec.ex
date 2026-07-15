defmodule Dramatizer.Generation.GenerationSpec do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "generation_specs" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :revision, Dramatizer.Revisions.Revision
    field :kind, :string
    field :candidate_index, :integer, default: 0
    field :formal, :boolean, default: true
    field :payload, :map
    field :payload_hash, :string

    timestamps()
  end

  def create_changeset(spec, attrs) do
    spec
    |> cast(attrs, [
      :project_id,
      :revision_id,
      :kind,
      :candidate_index,
      :formal,
      :payload,
      :payload_hash
    ])
    |> validate_required([:project_id, :kind, :candidate_index, :formal, :payload, :payload_hash])
    |> validate_number(:candidate_index, greater_than_or_equal_to: 0)
    |> unique_constraint([:project_id, :kind, :payload_hash, :candidate_index, :formal])
  end
end
