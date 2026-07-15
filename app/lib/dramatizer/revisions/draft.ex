defmodule Dramatizer.Revisions.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  alias Dramatizer.Revisions.Revision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "drafts" do
    belongs_to :project, Dramatizer.Projects.Project
    field :logical_id, Ecto.UUID
    field :kind, Ecto.Enum, values: Revision.kinds()
    field :status, Ecto.Enum, values: [:editing, :confirmed], default: :editing
    belongs_to :base_revision, Revision
    belongs_to :confirmed_revision, Revision
    field :payload, :map
    field :provenance, :map, default: %{}
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(draft, attrs) do
    draft
    |> cast(attrs, [:project_id, :logical_id, :kind, :base_revision_id, :payload, :provenance])
    |> validate_required([:project_id, :logical_id, :kind, :payload, :provenance])
  end

  def edit_changeset(draft, attrs) do
    draft
    |> cast(attrs, [:payload, :provenance])
    |> validate_required([:payload, :provenance])
    |> optimistic_lock(:lock_version)
  end

  def confirm_changeset(draft, revision_id) do
    draft
    |> change(status: :confirmed, confirmed_revision_id: revision_id)
    |> optimistic_lock(:lock_version)
  end
end
