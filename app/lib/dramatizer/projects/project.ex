defmodule Dramatizer.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :archived_at, :utc_datetime_usec

    has_one :production_profile, Dramatizer.Projects.ProductionProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :status, :archived_at])
    |> validate_required([:name, :status])
    |> validate_length(:name, min: 1, max: 200)
  end
end
