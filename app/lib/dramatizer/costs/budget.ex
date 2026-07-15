defmodule Dramatizer.Costs.Budget do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "project_budgets" do
    belongs_to :project, Dramatizer.Projects.Project
    field :limit_micros, :integer
    field :reserved_micros, :integer, default: 0
    field :actual_micros, :integer, default: 0
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(budget, attrs) do
    budget
    |> cast(attrs, [:project_id, :limit_micros])
    |> validate_required([:project_id])
    |> validate_number(:limit_micros, greater_than_or_equal_to: 0)
    |> unique_constraint(:project_id)
  end

  def projection_changeset(budget, attrs) do
    budget
    |> cast(attrs, [:limit_micros, :reserved_micros, :actual_micros])
    |> validate_number(:limit_micros, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_micros, greater_than_or_equal_to: 0)
    |> validate_number(:actual_micros, greater_than_or_equal_to: 0)
    |> optimistic_lock(:lock_version)
  end
end
