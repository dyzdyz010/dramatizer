defmodule Dramatizer.Sources.SourceRevision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "source_revisions" do
    belongs_to :source_document, Dramatizer.Sources.SourceDocument
    belongs_to :project, Dramatizer.Projects.Project
    field :revision, :integer
    belongs_to :parent_revision, __MODULE__
    belongs_to :asset_version, Dramatizer.Assets.AssetVersion
    field :source_format, Ecto.Enum, values: [:text, :markdown, :pdf]
    field :original_filename, :string
    field :parser_version, :string
    field :content_hash, :string
    field :character_count, :integer
    field :byte_count, :integer
    field :locators, :map
    field :metadata, :map, default: %{}

    timestamps()
  end

  def create_changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :source_document_id,
      :project_id,
      :revision,
      :parent_revision_id,
      :asset_version_id,
      :source_format,
      :original_filename,
      :parser_version,
      :content_hash,
      :character_count,
      :byte_count,
      :locators,
      :metadata
    ])
    |> validate_required([
      :source_document_id,
      :project_id,
      :revision,
      :asset_version_id,
      :source_format,
      :original_filename,
      :parser_version,
      :content_hash,
      :character_count,
      :byte_count,
      :locators,
      :metadata
    ])
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:character_count, greater_than: 0)
    |> validate_number(:byte_count, greater_than: 0)
    |> unique_constraint([:source_document_id, :revision])
  end
end
