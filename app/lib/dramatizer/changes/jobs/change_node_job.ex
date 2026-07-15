defmodule Dramatizer.Changes.Jobs.ChangeNodeJob do
  use Oban.Worker, queue: :workflow, max_attempts: 3

  alias Dramatizer.Changes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"change_node_id" => node_id}}) do
    case Changes.run_change_node(node_id) do
      {:ok, _node} -> :ok
      {:error, reason, _node} -> {:error, reason}
    end
  end
end
