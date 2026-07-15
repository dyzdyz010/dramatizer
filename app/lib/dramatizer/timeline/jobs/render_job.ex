defmodule Dramatizer.Timeline.Jobs.RenderJob do
  use Oban.Worker, queue: :media, max_attempts: 3

  alias Dramatizer.Repo
  alias Dramatizer.Timeline.RenderManifest
  alias Dramatizer.Timeline.RenderRecipe

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"render_manifest_id" => id}}) do
    id
    |> then(&Repo.get!(RenderManifest, &1))
    |> RenderRecipe.render()
    |> case do
      {:ok, _manifest} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
