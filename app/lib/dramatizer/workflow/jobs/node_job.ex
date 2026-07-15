defmodule Dramatizer.Workflow.Jobs.NodeJob do
  use Oban.Worker, queue: :workflow, max_attempts: 1

  alias Dramatizer.Workflow

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"node_run_id" => node_run_id}}) do
    _node = Workflow.get_node!(node_run_id)
    :ok
  end
end
