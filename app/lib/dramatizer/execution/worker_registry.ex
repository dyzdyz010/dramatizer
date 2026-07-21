defmodule Dramatizer.Execution.WorkerRegistry do
  @moduledoc "Allow-list for workers that may be reconstructed from persisted NodeRuns."

  @workers [
    Dramatizer.Workflow.Jobs.NodeJob,
    Dramatizer.Analysis.Jobs.AnalysisNodeJob,
    Dramatizer.Generation.Jobs.GenerationNodeJob,
    Dramatizer.Quality.Jobs.TechnicalQCJob,
    Dramatizer.Quality.Jobs.SemanticQCJob,
    Dramatizer.Timeline.Jobs.RenderJob,
    Dramatizer.Changes.Jobs.ChangeNodeJob
  ]

  def fetch(name) when is_binary(name) do
    case Enum.find(@workers, &(inspect(&1) == name)) do
      nil -> :error
      worker -> ensure_worker(worker)
    end
  end

  def fetch(_name), do: :error

  defp ensure_worker(worker) do
    if Code.ensure_loaded?(worker) and function_exported?(worker, :new, 2) do
      {:ok, worker}
    else
      :error
    end
  end
end
