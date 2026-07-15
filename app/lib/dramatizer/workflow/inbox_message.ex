defmodule Dramatizer.Workflow.InboxMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [inserted_at: false, updated_at: false]

  schema "inbox_messages" do
    field :provider, :string
    field :external_id, :string
    field :payload, :map
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
  end

  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [:provider, :external_id, :payload, :received_at])
    |> validate_required([:provider, :external_id, :payload, :received_at])
    |> unique_constraint([:provider, :external_id])
  end
end
