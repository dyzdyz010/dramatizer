defmodule Dramatizer.Quality.Jobs.SemanticQCJob do
  use Oban.Worker,
    queue: :qc,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Assets
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Projects
  alias Dramatizer.Quality.{SelectionDecision, SemanticQC}
  alias Dramatizer.Quality.Jobs.NodeRunner
  alias Dramatizer.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => _node_run_id}} = job),
    do: NodeRunner.perform(job)

  def perform(%Oban.Job{args: args}) do
    asset_id = Map.fetch!(args, "asset_version_id")
    spec_id = Map.fetch!(args, "generation_spec_id")
    asset = Assets.get_asset!(asset_id)
    spec = Repo.get!(GenerationSpec, spec_id)
    project = Projects.get_project!(asset.project_id)
    neighbors = selected_neighbors(Map.get(args, "selected_neighbor_ids", %{}))

    case SemanticQC.run(asset, spec, project,
           selected_neighbors: neighbors,
           evaluation_key: Map.get(args, "evaluation_key", "default")
         ) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)

  defp selected_neighbors(ids) do
    Enum.flat_map(ids, fn {position, id} ->
      case Repo.get(SelectionDecision, id) do
        %SelectionDecision{} = selection -> [{String.to_existing_atom(position), selection}]
        nil -> []
      end
    end)
  end
end
