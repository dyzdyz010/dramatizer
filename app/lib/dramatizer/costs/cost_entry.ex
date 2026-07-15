defmodule Dramatizer.Costs.CostEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "cost_entries" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :attempt, Dramatizer.Generation.Attempt
    field :entry_type, Ecto.Enum, values: [:estimate, :reservation, :actual]
    field :amount_micros, :integer
    field :currency, :string, default: "USD"
    field :idempotency_key, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :project_id,
      :attempt_id,
      :entry_type,
      :amount_micros,
      :currency,
      :idempotency_key,
      :metadata
    ])
    |> validate_required([:project_id, :entry_type, :currency, :idempotency_key, :metadata])
    |> validate_number(:amount_micros, greater_than_or_equal_to: 0)
    |> unique_constraint(:idempotency_key)
  end
end
