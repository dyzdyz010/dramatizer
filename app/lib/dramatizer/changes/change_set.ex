defmodule Dramatizer.Changes.ChangeSet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_sets" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :old_revision, Dramatizer.Revisions.Revision
    belongs_to :new_revision, Dramatizer.Revisions.Revision
    field :status, Ecto.Enum, values: [:confirmed, :running, :succeeded, :partial_failed]
    field :diff, :map
    field :graph_epoch, :integer
    field :selected_target_ids, {:array, Ecto.UUID}
    field :actions, :map
    field :idempotency_key, :string
    field :confirmed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(change_set, attrs) do
    change_set
    |> cast(attrs, [
      :project_id,
      :old_revision_id,
      :new_revision_id,
      :status,
      :diff,
      :graph_epoch,
      :selected_target_ids,
      :actions,
      :idempotency_key,
      :confirmed_at
    ])
    |> validate_required([
      :project_id,
      :old_revision_id,
      :new_revision_id,
      :status,
      :diff,
      :graph_epoch,
      :selected_target_ids,
      :actions,
      :idempotency_key,
      :confirmed_at
    ])
    |> unique_constraint(:idempotency_key)
  end

  def status_changeset(change_set, attrs) do
    change_set
    |> cast(attrs, [:status, :completed_at])
    |> validate_required([:status])
  end
end
