defmodule Dramatizer.Workflow.Enqueue do
  @moduledoc "Atomically binds a durable NodeRun to one incomplete Oban job."

  import Ecto.Query

  alias Dramatizer.Execution.Notifier
  alias Dramatizer.Repo
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}
  alias Ecto.Multi

  @unique [period: 86_400, fields: [:worker, :args], states: :incomplete]

  def node(%NodeRun{id: node_id}, worker, opts \\ []) when is_atom(worker) do
    job_opts = Keyword.get(opts, :job_options, [])

    result =
      Multi.new()
      |> Multi.run(:node, fn repo, _changes -> lock_queueable_node(repo, node_id, worker) end)
      |> Oban.insert(:job, fn %{node: current} ->
        worker.new(%{"node_run_id" => current.id}, Keyword.put(job_opts, :unique, @unique))
      end)
      |> Multi.run(:owned_node, fn repo, %{node: current, job: job} ->
        current
        |> NodeRun.transition_changeset(%{
          status: current.status,
          worker: job.worker,
          active_job_id: job.id,
          next_retry_at: job.scheduled_at
        })
        |> repo.update()
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{owned_node: owned_node, job: job}} ->
        notify(owned_node)
        {:ok, %{node: owned_node, job: job}}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp lock_queueable_node(repo, node_id, worker) do
    current =
      repo.one!(from node in NodeRun, where: node.id == ^node_id, lock: "FOR UPDATE")

    cond do
      current.status not in [:queued, :running] ->
        {:error, {:node_not_queueable, current.status}}

      current.worker not in [nil, inspect(worker)] ->
        {:error, :node_worker_mismatch}

      true ->
        {:ok, current}
    end
  end

  defp notify(node) do
    project_id =
      Repo.one!(
        from run in WorkflowRun,
          where: run.id == ^node.workflow_run_id,
          select: run.project_id
      )

    Notifier.broadcast(project_id, :workflow, node.id, node.status)
  end
end
