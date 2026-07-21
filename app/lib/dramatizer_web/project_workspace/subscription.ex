defmodule DramatizerWeb.ProjectWorkspace.Subscription do
  @moduledoc "Routes project-scoped execution invalidations to workspace data slices."

  alias Dramatizer.Execution.Notifier
  alias Dramatizer.Projects.Project

  def subscribe(%Project{id: project_id}), do: Notifier.subscribe(project_id)
  def subscribe(project_id) when is_binary(project_id), do: Notifier.subscribe(project_id)

  def slice_for(%{resource: :analysis}), do: :analysis
  def slice_for(%{resource: resource}) when resource in [:generation, :quality], do: :generation
  def slice_for(%{resource: :timeline}), do: :timeline
  def slice_for(%{resource: :changes}), do: :changes
  def slice_for(%{resource: :workflow}), do: :execution
  def slice_for(_event), do: :ignore
end
