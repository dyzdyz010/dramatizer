defmodule Dramatizer.Assets.AssetVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "asset_versions" do
    belongs_to :project, Dramatizer.Projects.Project
    belongs_to :upload_intent, Dramatizer.Assets.UploadIntent
    field :kind, :string
    field :source, :string
    belongs_to :parent_asset, __MODULE__
    field :blob_hash, :string
    field :relative_path, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :duration_ms, :integer
    field :metadata, :map, default: %{}
    field :lineage, :map, default: %{}

    timestamps()
  end

  def create_changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :project_id,
      :upload_intent_id,
      :kind,
      :source,
      :parent_asset_id,
      :blob_hash,
      :relative_path,
      :mime_type,
      :byte_size,
      :width,
      :height,
      :duration_ms,
      :metadata,
      :lineage
    ])
    |> validate_required([
      :project_id,
      :upload_intent_id,
      :kind,
      :source,
      :blob_hash,
      :relative_path,
      :mime_type,
      :byte_size,
      :metadata,
      :lineage
    ])
    |> validate_number(:byte_size, greater_than: 0)
    |> unique_constraint(:upload_intent_id)
    |> foreign_key_constraint(:parent_asset_id)
  end
end
