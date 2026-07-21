defmodule Dramatizer.Repo.Migrations.AddExecutionFieldsToNodeRuns do
  use Ecto.Migration

  def change do
    alter table(:node_runs) do
      add :worker, :text
      add :active_job_id, :bigint
      add :lease_expires_at, :utc_datetime_usec
      add :next_retry_at, :utc_datetime_usec
    end

    create index(:node_runs, [:status, :lease_expires_at])
    create index(:node_runs, [:active_job_id])
  end
end
