defmodule Dramatizer.Execution.Notifier do
  @moduledoc "Project-scoped invalidation events for durable execution state."

  @resources ~w(analysis generation quality timeline changes workflow)a

  def topic(project_id) when is_binary(project_id),
    do: "project:#{project_id}:execution"

  def subscribe(project_id) do
    with :ok <- validate_id(project_id, :invalid_project_id) do
      Phoenix.PubSub.subscribe(Dramatizer.PubSub, topic(project_id))
    end
  end

  def broadcast(project_id, resource, resource_id, event) do
    with :ok <- validate_id(project_id, :invalid_project_id),
         :ok <- validate_resource(resource),
         :ok <- validate_id(resource_id, :invalid_resource_id),
         :ok <- validate_event(event) do
      Phoenix.PubSub.broadcast(
        Dramatizer.PubSub,
        topic(project_id),
        {:execution_changed,
         %{
           project_id: project_id,
           resource: resource,
           resource_id: resource_id,
           event: event
         }}
      )
    end
  end

  defp validate_id(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, _id} -> :ok
      :error -> {:error, error}
    end
  end

  defp validate_resource(resource) when resource in @resources, do: :ok
  defp validate_resource(_resource), do: {:error, :invalid_resource}

  defp validate_event(event) when is_atom(event), do: :ok
  defp validate_event(_event), do: {:error, :invalid_event}
end
