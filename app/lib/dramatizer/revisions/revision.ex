defmodule Dramatizer.Revisions.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]
  @kinds [:narrative, :visual_design, :reference_set, :shot_plan, :generation_spec, :timeline]

  schema "revisions" do
    belongs_to :project, Dramatizer.Projects.Project
    field :logical_id, Ecto.UUID
    field :kind, Ecto.Enum, values: @kinds
    field :revision, :integer
    belongs_to :parent_revision, __MODULE__
    field :draft_id, Ecto.UUID
    field :payload, :map
    field :provenance, :map, default: %{}
    field :profile_snapshot, :map
    field :content_hash, :string

    timestamps()
  end

  def kinds, do: @kinds

  def create_changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :project_id,
      :logical_id,
      :kind,
      :revision,
      :parent_revision_id,
      :draft_id,
      :payload,
      :provenance,
      :profile_snapshot,
      :content_hash
    ])
    |> validate_required([
      :project_id,
      :logical_id,
      :kind,
      :revision,
      :draft_id,
      :payload,
      :provenance,
      :profile_snapshot,
      :content_hash
    ])
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint([:logical_id, :revision])
    |> unique_constraint(:draft_id)
  end
end
