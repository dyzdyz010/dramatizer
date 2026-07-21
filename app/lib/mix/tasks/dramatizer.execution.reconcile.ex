defmodule Mix.Tasks.Dramatizer.Execution.Reconcile do
  use Mix.Task

  @shortdoc "Reconciles orphaned durable execution nodes"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Dramatizer.Execution.ReconcilerJob.reconcile() do
      {:ok, counts} ->
        Mix.shell().info(
          "execution reconciliation: extended=#{counts.extended} " <>
            "preserved=#{counts.preserved} requeued=#{counts.requeued} failed=#{counts.failed}"
        )

      {:error, reason} ->
        Mix.raise("execution reconciliation failed: #{inspect(reason)}")
    end
  end
end
