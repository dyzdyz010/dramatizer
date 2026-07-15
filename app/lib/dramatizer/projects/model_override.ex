defmodule Dramatizer.Projects.ModelOverride do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_overrides" do
    belongs_to :project, Dramatizer.Projects.Project
    field :task_type, :string
    field :adapter, :string
    field :credential_ref, :string
    field :model, :string
    field :params, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:project_id, :task_type, :adapter, :credential_ref, :model, :params])
    |> validate_required([:project_id, :task_type, :params])
    |> validate_change(:params, &validate_params/2)
    |> unique_constraint([:project_id, :task_type])
  end

  defp validate_params(:params, params) do
    candidate_count = Map.get(params, "candidate_count", Map.get(params, :candidate_count))

    if is_nil(candidate_count) or (is_integer(candidate_count) and candidate_count > 0) do
      []
    else
      [params: "must be a positive integer"]
    end
  end
end
