defmodule Dramatizer.Workflow.OutboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec]

  schema "outbox_events" do
    field :aggregate_type, :string
    field :aggregate_id, Ecto.UUID
    field :event_type, :string
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :published], default: :pending
    field :idempotency_key, :string
    field :published_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [:aggregate_type, :aggregate_id, :event_type, :payload, :idempotency_key])
    |> validate_required([
      :aggregate_type,
      :aggregate_id,
      :event_type,
      :payload,
      :idempotency_key
    ])
    |> unique_constraint(:idempotency_key)
  end
end
