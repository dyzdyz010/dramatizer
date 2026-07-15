defmodule Dramatizer.Quality.Jobs.SemanticQCJob do
  use Oban.Worker, queue: :qc, max_attempts: 1

  alias Dramatizer.Assets
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Projects
  alias Dramatizer.Quality.SemanticQC
  alias Dramatizer.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"asset_version_id" => asset_id, "generation_spec_id" => spec_id}
      }) do
    asset = Assets.get_asset!(asset_id)
    spec = Repo.get!(GenerationSpec, spec_id)
    project = Projects.get_project!(asset.project_id)

    case SemanticQC.run(asset, spec, project) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
