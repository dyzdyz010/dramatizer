defmodule Dramatizer.Timeline.Jobs.RenderJob do
  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Execution.{JobGuard, Notifier, WorkerLifecycle}
  alias Dramatizer.Execution.JobResult
  alias Dramatizer.Repo
  alias Dramatizer.Timeline.RenderManifest
  alias Dramatizer.Timeline.RenderRecipe
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.WorkflowRun

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc false
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}} = job, opts) do
    node = Workflow.get_node!(node_run_id)
    manifest = Repo.get!(RenderManifest, node.input_snapshot["render_manifest_id"])

    case WorkerLifecycle.start(node, job) do
      {:ok, running} -> guarded_execute(running, manifest, job, opts)
      {:skip, :terminal} -> resume_terminal(node, manifest)
      {:skip, _reason} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp execute(node, manifest, job, opts) do
    renderer = Keyword.get(opts, :renderer, &RenderRecipe.render/1)

    case renderer.(manifest) do
      {:ok, rendered} ->
        result = %{
          "render_manifest_id" => rendered.id,
          "output_asset_id" => rendered.output_asset_id,
          "srt_asset_id" => rendered.srt_asset_id,
          "recipe_hash" => rendered.recipe_hash
        }

        commit_success(node, rendered, job, result)

      {:error, reason} ->
        fail(node, manifest, job, reason)
    end
  end

  defp guarded_execute(node, manifest, job, opts) do
    case JobGuard.protect(fn -> execute(node, manifest, job, opts) end) do
      {:ok, result} -> result
      {:error, reason, _details} -> fail(node, manifest, job, reason)
    end
  end

  defp complete_run(node, _manifest) do
    run = Repo.get!(WorkflowRun, node.workflow_run_id)

    with {:ok, _run} <- Workflow.mark_run(run, :succeeded) do
      :ok
    end
  end

  defp fail(node, manifest, job, reason) do
    details = %{"render_manifest_id" => manifest.id}

    transaction =
      Repo.transaction(fn ->
        case WorkerLifecycle.fail(node, job, reason, details, notify: false) do
          {:retry, _queued, _delay} ->
            reset_manifest_for_retry(manifest)
            :retry

          {terminal, terminal_node} when terminal in [:failed, :cancelled] ->
            with {:ok, _manifest} <- fail_manifest(manifest, reason),
                 :ok <- fail_run(terminal_node, manifest) do
              :terminal
            else
              {:error, failure_reason} -> Repo.rollback(failure_reason)
            end

          {:skip, _reason} ->
            :skip

          {:error, lifecycle_reason} ->
            Repo.rollback(lifecycle_reason)
        end
      end)

    case transaction do
      {:ok, :retry} ->
        notify_after_commit(manifest, node.id, :queued)
        {:error, inspect(reason)}

      {:ok, :terminal} ->
        notify_after_commit(manifest, node.id, :failed)
        :ok

      {:ok, :skip} ->
        :ok

      {:error, lifecycle_reason} ->
        {:error, inspect(lifecycle_reason)}
    end
  end

  defp commit_success(node, manifest, job, result) do
    transaction =
      Repo.transaction(fn ->
        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result, notify: false),
             :ok <- complete_run(completed, manifest) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, manifest, node.id, :succeeded)
  end

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{status: :succeeded} = node, manifest) do
    transaction =
      Repo.transaction(fn ->
        case complete_run(node, manifest) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, manifest, node.id, :succeeded)
  end

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{status: status} = node, manifest)
       when status in [:failed, :cancelled] do
    transaction =
      Repo.transaction(fn ->
        case fail_run(node, manifest) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    finish_transaction(transaction, manifest, node.id, :failed)
  end

  defp resume_terminal(%Dramatizer.Workflow.NodeRun{}, _manifest), do: :ok

  defp fail_run(node, _manifest) do
    run = Repo.get!(WorkflowRun, node.workflow_run_id)

    with {:ok, _run} <- Workflow.mark_run(run, :failed) do
      :ok
    end
  end

  defp reset_manifest_for_retry(manifest) do
    RenderManifest
    |> Repo.get!(manifest.id)
    |> RenderManifest.status_changeset(%{
      status: :prepared,
      technical_qc: %{},
      error_code: nil
    })
    |> Repo.update!()
  end

  defp fail_manifest(manifest, reason) do
    {_classification, code} = JobResult.classify(reason)

    RenderManifest
    |> Repo.get!(manifest.id)
    |> RenderManifest.status_changeset(%{
      status: :failed,
      technical_qc: %{},
      error_code: code
    })
    |> Repo.update()
  end

  defp finish_transaction({:ok, :ok}, manifest, node_id, status) do
    notify_after_commit(manifest, node_id, status)
    :ok
  end

  defp finish_transaction({:error, reason}, _manifest, _node_id, _status),
    do: {:error, inspect(reason)}

  defp notify_after_commit(manifest, node_id, status) do
    Notifier.broadcast(manifest.project_id, :workflow, node_id, status)
    Notifier.broadcast(manifest.project_id, :timeline, manifest.id, status)
  end
end
