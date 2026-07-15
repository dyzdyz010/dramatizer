defmodule Dramatizer.Generation.Attempt do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses [:prepared, :submitted, :succeeded, :failed, :timed_out, :unknown_remote_state]
  @type t :: %__MODULE__{}

  schema "attempts" do
    belongs_to :provider_request_snapshot, Dramatizer.Generation.ProviderRequestSnapshot
    belongs_to :node_run, Dramatizer.Workflow.NodeRun
    field :attempt_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :prepared
    field :idempotency_key, :string
    field :external_request_id, :string
    belongs_to :result_asset, Dramatizer.Assets.AssetVersion
    field :response_metadata, :map, default: %{}
    field :error_code, :string
    field :error_message, :string
    field :submitted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :provider_request_snapshot_id,
      :node_run_id,
      :attempt_number,
      :idempotency_key
    ])
    |> validate_required([:provider_request_snapshot_id, :attempt_number, :idempotency_key])
    |> validate_number(:attempt_number, greater_than: 0)
    |> unique_constraint([:provider_request_snapshot_id, :attempt_number])
    |> unique_constraint(:idempotency_key)
  end

  def transition_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :status,
      :external_request_id,
      :result_asset_id,
      :response_metadata,
      :error_code,
      :error_message,
      :submitted_at,
      :completed_at
    ])
    |> validate_required([:status, :response_metadata])
    |> optimistic_lock(:lock_version)
  end
end
