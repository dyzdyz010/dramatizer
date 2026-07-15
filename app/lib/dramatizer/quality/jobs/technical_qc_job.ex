defmodule Dramatizer.Quality.Jobs.TechnicalQCJob do
  use Oban.Worker, queue: :qc, max_attempts: 3

  alias Dramatizer.Assets
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Quality.TechnicalQC
  alias Dramatizer.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"asset_version_id" => asset_id, "generation_spec_id" => spec_id}
      }) do
    asset = Assets.get_asset!(asset_id)
    spec = Repo.get!(GenerationSpec, spec_id)

    case TechnicalQC.run(asset, spec) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
