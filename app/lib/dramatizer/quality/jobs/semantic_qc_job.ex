defmodule Dramatizer.Quality.Jobs.SemanticQCJob do
  use Oban.Worker, queue: :qc, max_attempts: 1

  alias Dramatizer.Assets
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Projects
  alias Dramatizer.Quality.{SelectionDecision, SemanticQC}
  alias Dramatizer.Repo

  @impl Oban.Worker
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

  defp selected_neighbors(ids) do
    Enum.flat_map(ids, fn {position, id} ->
      case Repo.get(SelectionDecision, id) do
        %SelectionDecision{} = selection -> [{String.to_existing_atom(position), selection}]
        nil -> []
      end
    end)
  end
end
