defmodule Dramatizer.CostsTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Costs
  alias Dramatizer.Projects

  test "budget reservations are transactional and actual cost is never invented" do
    assert {:ok, project} = Projects.create_project(%{name: "成本测试"})
    assert {:ok, budget} = Costs.set_budget(project, 1_000)
    assert budget.limit_micros == 1_000

    assert {:ok, estimate} =
             Costs.record_estimate(project, 700, "estimate-1", %{"task" => "image"})

    assert estimate.entry_type == :estimate

    assert {:ok, reservation} = Costs.reserve(project, 700, "reserve-1")
    assert reservation.entry_type == :reservation
    assert {:ok, same_reservation} = Costs.reserve(project, 700, "reserve-1")
    assert same_reservation.id == reservation.id
    assert Costs.get_budget(project).reserved_micros == 700
    assert {:error, :budget_exhausted} = Costs.reserve(project, 400, "reserve-2")

    assert {:ok, actual} = Costs.settle(reservation, 650, %{"provider" => "fake"})
    assert actual.entry_type == :actual
    assert actual.amount_micros == 650
    assert {:ok, same_actual} = Costs.settle(reservation, 650, %{"provider" => "fake"})
    assert same_actual.id == actual.id

    assert {:ok, second_reservation} = Costs.reserve(project, 300, "reserve-3")

    assert {:ok, unknown_actual} =
             Costs.settle(second_reservation, nil, %{"reason" => "not_reported"})

    assert unknown_actual.amount_micros == nil

    projection = Costs.get_budget(project)
    assert projection.reserved_micros == 0
    assert projection.actual_micros == 650
  end
end
