defmodule Dramatizer.Changes.ChangeNode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_nodes" do
    belongs_to :change_set, Dramatizer.Changes.ChangeSet
    field :node_key, :string
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :action, :string
    field :status, Ecto.Enum, values: [:pending, :running, :succeeded, :failed], default: :pending
    field :input_snapshot, :map
    field :input_hash, :string
    field :result, :map, default: %{}
    field :error_code, :string
    field :attempt_count, :integer, default: 0
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :change_set_id,
      :node_key,
      :target_type,
      :target_id,
      :action,
      :status,
      :input_snapshot,
      :input_hash
    ])
    |> validate_required([
      :change_set_id,
      :node_key,
      :target_type,
      :target_id,
      :action,
      :status,
      :input_snapshot,
      :input_hash
    ])
    |> unique_constraint([:change_set_id, :node_key])
  end

  def execution_changeset(node, attrs) do
    node
    |> cast(attrs, [:status, :result, :error_code, :attempt_count])
    |> validate_required([:status, :result, :attempt_count])
    |> optimistic_lock(:lock_version)
  end
end
