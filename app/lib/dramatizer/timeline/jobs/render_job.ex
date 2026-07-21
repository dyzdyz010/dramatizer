defmodule Dramatizer.Timeline.Jobs.RenderJob do
  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Execution.{Notifier, WorkerLifecycle}
  alias Dramatizer.Repo
  alias Dramatizer.Timeline.RenderManifest
  alias Dramatizer.Timeline.RenderRecipe
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.WorkflowRun

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}} = job) do
    node = Workflow.get_node!(node_run_id)
    manifest = Repo.get!(RenderManifest, node.input_snapshot["render_manifest_id"])

    case WorkerLifecycle.start(node, job) do
      {:ok, running} -> execute(running, manifest, job)
      {:skip, _reason} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp execute(node, manifest, job) do
    case RenderRecipe.render(manifest) do
      {:ok, rendered} ->
        result = %{
          "render_manifest_id" => rendered.id,
          "output_asset_id" => rendered.output_asset_id,
          "srt_asset_id" => rendered.srt_asset_id,
          "recipe_hash" => rendered.recipe_hash
        }

        with {:ok, completed} <- WorkerLifecycle.succeed(node, job, result),
             :ok <- complete_run(completed, rendered) do
          :ok
        else
          {:skip, _reason} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        fail(node, manifest, job, reason)
    end
  end

  defp complete_run(node, manifest) do
    run = Repo.get!(WorkflowRun, node.workflow_run_id)

    with {:ok, _run} <- Workflow.mark_run(run, :succeeded) do
      Notifier.broadcast(manifest.project_id, :timeline, manifest.id, :succeeded)
    end
  end

  defp fail(node, manifest, job, reason) do
    details = %{"render_manifest_id" => manifest.id}

    case WorkerLifecycle.fail(node, job, reason, details) do
      {:retry, _queued, _delay} ->
        {:error, inspect(reason)}

      {terminal, _node} when terminal in [:failed, :cancelled] ->
        run = Repo.get!(WorkflowRun, node.workflow_run_id)
        Workflow.mark_run(run, :failed)
        Notifier.broadcast(manifest.project_id, :timeline, manifest.id, :failed)

      {:skip, _reason} ->
        :ok

      {:error, lifecycle_reason} ->
        {:error, inspect(lifecycle_reason)}
    end
  end
end
