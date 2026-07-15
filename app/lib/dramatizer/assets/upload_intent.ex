defmodule Dramatizer.Assets.UploadIntent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "upload_intents" do
    belongs_to :project, Dramatizer.Projects.Project
    field :purpose, :string
    field :status, Ecto.Enum, values: [:staging, :failed, :finalized], default: :staging
    field :staging_path, :string
    field :expected_mime, :string
    field :byte_size, :integer
    field :sha256, :string
    field :idempotency_key, :string
    field :error_code, :string
    field :finalized_asset_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(intent, attrs) do
    intent
    |> cast(attrs, [:project_id, :purpose, :staging_path, :expected_mime, :idempotency_key])
    |> validate_required([:project_id, :purpose, :staging_path, :idempotency_key])
    |> unique_constraint([:project_id, :idempotency_key])
  end

  def stage_changeset(intent, attrs) do
    intent
    |> cast(attrs, [:status, :byte_size, :sha256, :error_code])
    |> validate_required([:status, :byte_size, :sha256])
  end

  def fail_changeset(intent, error_code) do
    change(intent, status: :failed, error_code: to_string(error_code))
  end

  def finalize_changeset(intent, asset_id) do
    change(intent, status: :finalized, finalized_asset_id: asset_id, error_code: nil)
  end
end
