defmodule Dramatizer.Generation.ProviderRequestSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]
  @type t :: %__MODULE__{}

  schema "provider_request_snapshots" do
    belongs_to :generation_spec, Dramatizer.Generation.GenerationSpec
    belongs_to :node_run, Dramatizer.Workflow.NodeRun
    field :task_type, :string
    field :adapter, :string
    field :credential_ref, :string
    field :model, :string
    field :params, :map, default: %{}
    field :request_input, :map
    field :prompt_snapshot, :map, default: %{}
    field :request_hash, :string
    field :secrets_excluded, :boolean, default: true

    timestamps()
  end

  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :generation_spec_id,
      :node_run_id,
      :task_type,
      :adapter,
      :credential_ref,
      :model,
      :params,
      :request_input,
      :prompt_snapshot,
      :request_hash,
      :secrets_excluded
    ])
    |> validate_required([
      :generation_spec_id,
      :task_type,
      :adapter,
      :credential_ref,
      :model,
      :params,
      :request_input,
      :prompt_snapshot,
      :request_hash,
      :secrets_excluded
    ])
    |> unique_constraint([:generation_spec_id, :request_hash])
  end
end
