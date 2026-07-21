defmodule Dramatizer.Workflow.Enqueue do
  @moduledoc "Atomically binds durable NodeRuns to their incomplete Oban jobs."

  import Ecto.Query

  alias Dramatizer.Execution.Notifier
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}
  alias Ecto.Multi

  @unique [period: 86_400, fields: [:worker, :args], states: :incomplete]

  def node(%NodeRun{id: node_id}, worker, opts \\ []) when is_atom(worker) do
    job_opts = Keyword.get(opts, :job_options, [])
    notify? = Keyword.get(opts, :notify, true)

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
        if notify?, do: notify(owned_node)
        {:ok, %{node: owned_node, job: job}}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc "Transitions every ready child and inserts its job in one transaction."
  def ready_nodes(workflow_run_id, worker_resolver, opts \\ [])
      when is_function(worker_resolver, 1) do
    transaction =
      Repo.transaction(fn ->
        blocked =
          Repo.all(
            from node in NodeRun,
              where: node.workflow_run_id == ^workflow_run_id and node.status == :blocked,
              lock: "FOR UPDATE"
          )

        Enum.reduce(blocked, [], fn blocked_node, executions ->
          if ready?(blocked_node) do
            with {:ok, queued} <- Workflow.transition_locked(blocked_node, :queued, %{}),
                 {:ok, execution} <-
                   node(queued, worker_resolver.(queued),
                     job_options: Keyword.get(opts, :job_options, []),
                     notify: false
                   ) do
              [execution | executions]
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            executions
          end
        end)
        |> Enum.reverse()
      end)

    case transaction do
      {:ok, executions} ->
        if Keyword.get(opts, :notify, true) do
          Enum.each(executions, &notify(&1.node))
        end

        {:ok, executions}

      {:error, reason} ->
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

  defp ready?(node) do
    parents =
      Repo.all(
        from parent in NodeRun,
          where:
            parent.workflow_run_id == ^node.workflow_run_id and
              parent.node_key in ^node.required_parent_keys,
          select: {parent.node_key, parent.status}
      )
      |> Map.new()

    Enum.all?(node.required_parent_keys, &(Map.get(parents, &1) == :succeeded))
  end

  @doc false
  def notify(node) do
    project_id =
      Repo.one!(
        from run in WorkflowRun,
          where: run.id == ^node.workflow_run_id,
          select: run.project_id
      )

    Notifier.broadcast(project_id, :workflow, node.id, node.status)
  end
end
