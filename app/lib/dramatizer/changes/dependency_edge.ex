defmodule Dramatizer.Changes.DependencyEdge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "dependency_edges" do
    belongs_to :project, Dramatizer.Projects.Project
    field :upstream_type, :string
    field :upstream_id, Ecto.UUID
    field :downstream_type, :string
    field :downstream_id, Ecto.UUID
    field :relation, :string, default: "depends_on"
    field :graph_epoch, :integer, default: 1
    field :metadata, :map, default: %{}

    timestamps()
  end

  def create_changeset(edge, attrs) do
    edge
    |> cast(attrs, [
      :project_id,
      :upstream_type,
      :upstream_id,
      :downstream_type,
      :downstream_id,
      :relation,
      :graph_epoch,
      :metadata
    ])
    |> validate_required([
      :project_id,
      :upstream_type,
      :upstream_id,
      :downstream_type,
      :downstream_id,
      :relation,
      :graph_epoch,
      :metadata
    ])
    |> validate_number(:graph_epoch, greater_than: 0)
    |> unique_constraint(
      [
        :project_id,
        :upstream_type,
        :upstream_id,
        :downstream_type,
        :downstream_id,
        :graph_epoch
      ],
      name: :dependency_edges_exact_unique
    )
  end
end
