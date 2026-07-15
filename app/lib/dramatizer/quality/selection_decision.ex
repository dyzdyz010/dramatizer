defmodule Dramatizer.Quality.SelectionDecision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "selection_decisions" do
    belongs_to :project, Dramatizer.Projects.Project
    field :slot_key, :string
    belongs_to :generation_spec, Dramatizer.Generation.GenerationSpec
    belongs_to :asset_version, Dramatizer.Assets.AssetVersion
    field :status, Ecto.Enum, values: [:active, :superseded], default: :active
    field :accepted_semantic_failure, :boolean, default: false
    field :note, :string
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :project_id,
      :slot_key,
      :generation_spec_id,
      :asset_version_id,
      :accepted_semantic_failure,
      :note,
      :decided_at
    ])
    |> validate_required([
      :project_id,
      :slot_key,
      :generation_spec_id,
      :asset_version_id,
      :accepted_semantic_failure,
      :decided_at
    ])
    |> unique_constraint([:project_id, :slot_key], name: :selection_decisions_one_active_slot)
  end

  def supersede_changeset(decision) do
    change(decision, status: :superseded)
  end
end
