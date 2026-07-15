defmodule Dramatizer.Projects.PromptAppendix do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "prompt_appendices" do
    belongs_to :project, Dramatizer.Projects.Project
    field :task_type, :string
    field :revision, :integer
    field :body, :string
    field :body_hash, :string

    timestamps()
  end

  def changeset(appendix, attrs) do
    appendix
    |> cast(attrs, [:project_id, :task_type, :revision, :body, :body_hash])
    |> validate_required([:project_id, :task_type, :revision, :body, :body_hash])
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint([:project_id, :task_type, :revision])
  end
end
