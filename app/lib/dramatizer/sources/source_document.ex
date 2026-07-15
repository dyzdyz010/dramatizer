defmodule Dramatizer.Sources.SourceDocument do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "source_documents" do
    belongs_to :project, Dramatizer.Projects.Project
    field :role, Ecto.Enum, values: [:volume, :companion]
    field :name, :string

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(document, attrs) do
    document
    |> cast(attrs, [:project_id, :role, :name])
    |> validate_required([:project_id, :role, :name])
  end
end
