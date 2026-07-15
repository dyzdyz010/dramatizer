defmodule Dramatizer.Changes.StaleRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stale_records" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :change_set, Dramatizer.Changes.ChangeSet
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :reason, :string
    field :old_input_id, Ecto.UUID
    field :new_input_id, Ecto.UUID

    field :resolution, Ecto.Enum,
      values: [:unresolved, :pin_old_input, :replaced],
      default: :unresolved

    belongs_to :replacement_asset, Dramatizer.Assets.AssetVersion
    field :idempotency_key, :string
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :project_id,
      :change_set_id,
      :subject_type,
      :subject_id,
      :reason,
      :old_input_id,
      :new_input_id,
      :idempotency_key
    ])
    |> validate_required([
      :project_id,
      :subject_type,
      :subject_id,
      :reason,
      :resolution,
      :idempotency_key
    ])
    |> unique_constraint(:idempotency_key)
  end

  def resolve_changeset(record, attrs) do
    record
    |> cast(attrs, [:resolution, :replacement_asset_id, :resolved_at])
    |> validate_required([:resolution, :resolved_at])
  end
end
