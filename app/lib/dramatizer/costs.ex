defmodule Dramatizer.Costs do
  @moduledoc "Project cost estimates, transactional reservations, and actual-cost projection."

  import Ecto.Query

  alias Dramatizer.Costs.{Budget, CostEntry}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo

  def set_budget(%Project{id: project_id}, limit_micros)
      when is_integer(limit_micros) and limit_micros >= 0 do
    ensure_budget(project_id)

    project_id
    |> get_budget_for_update()
    |> Budget.projection_changeset(%{limit_micros: limit_micros})
    |> Repo.update()
  end

  def get_budget(%Project{id: project_id}) do
    ensure_budget(project_id)
    Repo.get_by!(Budget, project_id: project_id)
  end

  def record_estimate(
        %Project{id: project_id},
        amount_micros,
        idempotency_key,
        metadata,
        attempt_id \\ nil
      )
      when is_integer(amount_micros) and amount_micros >= 0 do
    insert_entry(%{
      project_id: project_id,
      attempt_id: attempt_id,
      entry_type: :estimate,
      amount_micros: amount_micros,
      idempotency_key: idempotency_key,
      metadata: metadata
    })
  end

  def reserve(%Project{id: project_id}, amount_micros, idempotency_key, attempt_id \\ nil)
      when is_integer(amount_micros) and amount_micros >= 0 do
    ensure_budget(project_id)

    Repo.transaction(fn ->
      budget = get_budget_for_update(project_id)

      case Repo.get_by(CostEntry, idempotency_key: idempotency_key) do
        %CostEntry{project_id: ^project_id, entry_type: :reservation} = existing ->
          existing

        nil ->
          projected = budget.actual_micros + budget.reserved_micros + amount_micros

          if is_integer(budget.limit_micros) and projected > budget.limit_micros do
            Repo.rollback(:budget_exhausted)
          end

          reservation =
            %CostEntry{}
            |> CostEntry.create_changeset(%{
              project_id: project_id,
              attempt_id: attempt_id,
              entry_type: :reservation,
              amount_micros: amount_micros,
              idempotency_key: idempotency_key,
              metadata: %{}
            })
            |> Repo.insert!()

          budget
          |> Budget.projection_changeset(%{
            reserved_micros: budget.reserved_micros + amount_micros
          })
          |> Repo.update!()

          reservation

        _other ->
          Repo.rollback(:idempotency_conflict)
      end
    end)
    |> unwrap()
  end

  def settle(%CostEntry{entry_type: :reservation} = reservation, actual_micros, metadata)
      when is_nil(actual_micros) or (is_integer(actual_micros) and actual_micros >= 0) do
    Repo.transaction(fn ->
      budget = get_budget_for_update(reservation.project_id)
      actual_key = "actual:#{reservation.id}"

      case Repo.get_by(CostEntry, idempotency_key: actual_key) do
        %CostEntry{entry_type: :actual} = existing ->
          existing

        nil ->
          released = max(0, budget.reserved_micros - reservation.amount_micros)
          actual_total = budget.actual_micros + (actual_micros || 0)

          actual =
            %CostEntry{}
            |> CostEntry.create_changeset(%{
              project_id: reservation.project_id,
              attempt_id: reservation.attempt_id,
              entry_type: :actual,
              amount_micros: actual_micros,
              idempotency_key: actual_key,
              metadata: metadata
            })
            |> Repo.insert!()

          budget
          |> Budget.projection_changeset(%{
            reserved_micros: released,
            actual_micros: actual_total
          })
          |> Repo.update!()

          actual
      end
    end)
    |> unwrap()
  end

  defp ensure_budget(project_id) do
    %Budget{}
    |> Budget.create_changeset(%{project_id: project_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:project_id])
  end

  defp get_budget_for_update(project_id) do
    Repo.one!(from budget in Budget, where: budget.project_id == ^project_id, lock: "FOR UPDATE")
  end

  defp insert_entry(attrs) do
    changeset = CostEntry.create_changeset(%CostEntry{}, attrs)
    idempotency_key = Ecto.Changeset.get_field(changeset, :idempotency_key)

    Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:idempotency_key])
    {:ok, Repo.get_by!(CostEntry, idempotency_key: idempotency_key)}
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
