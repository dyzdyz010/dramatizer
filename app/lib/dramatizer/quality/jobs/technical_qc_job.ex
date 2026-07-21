defmodule Dramatizer.Quality.Jobs.TechnicalQCJob do
  use Oban.Worker,
    queue: :qc,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias Dramatizer.Assets
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Quality.Jobs.NodeRunner
  alias Dramatizer.Quality.TechnicalQC
  alias Dramatizer.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => _node_run_id}} = job),
    do: NodeRunner.perform(job)

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

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(300, trunc(:math.pow(2, attempt)) * 5)
end
