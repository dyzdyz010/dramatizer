defmodule Dramatizer.Execution.NotifierTest do
  use ExUnit.Case, async: true

  alias Dramatizer.Execution.Notifier

  test "project topic is stable" do
    project_id = Ecto.UUID.generate()

    assert Notifier.topic(project_id) == "project:#{project_id}:execution"
  end

  test "broadcast carries identifiers and invalidation facts only" do
    project_id = Ecto.UUID.generate()
    resource_id = Ecto.UUID.generate()

    assert :ok = Notifier.subscribe(project_id)
    assert :ok = Notifier.broadcast(project_id, :generation, resource_id, :queued)

    assert_receive {:execution_changed,
                    %{
                      project_id: ^project_id,
                      resource: :generation,
                      resource_id: ^resource_id,
                      event: :queued
                    }}
  end

  test "rejects malformed identifiers and events before broadcasting" do
    assert {:error, :invalid_project_id} =
             Notifier.broadcast("not-a-uuid", :generation, Ecto.UUID.generate(), :queued)

    assert {:error, :invalid_resource_id} =
             Notifier.broadcast(Ecto.UUID.generate(), :generation, "not-a-uuid", :queued)

    assert {:error, :invalid_event} =
             Notifier.broadcast(Ecto.UUID.generate(), :generation, Ecto.UUID.generate(), "queued")
  end
end
