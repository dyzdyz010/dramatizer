defmodule Dramatizer.Generation.Orchestrator do
  @moduledoc "Runs Fake and real providers through one persisted generation contract."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Costs
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Generation.Adapters.Fake
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality
  alias Dramatizer.Repo
  alias Dramatizer.Workflow

  def generate(spec, task_type, project, opts \\ [])

  def generate(%GenerationSpec{} = spec, task_type, %Project{} = project, opts) do
    fault_profile = opts |> Keyword.get(:fault_profile, %{}) |> stringify_keys()

    prepare_options = %{
      task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
      request_input: %{
        "generation_spec" => spec.payload,
        "fault_profile" => fault_profile
      },
      prompt_snapshot: Keyword.get(opts, :prompt_snapshot, %{})
    }

    with {:ok, snapshot, _first_attempt} <-
           Generation.prepare_attempt(spec, task_type, project, prepare_options),
         {:ok, attempt} <- runnable_attempt(snapshot),
         result <- dispatch(spec, project, snapshot, attempt) do
      result
    end
  end

  defp runnable_attempt(snapshot) do
    latest =
      Repo.one!(
        from attempt in Attempt,
          where: attempt.provider_request_snapshot_id == ^snapshot.id,
          order_by: [desc: attempt.attempt_number],
          limit: 1
      )

    case latest.status do
      :prepared -> {:ok, latest}
      status when status in [:failed, :timed_out] -> Generation.retry_attempt(latest)
      :succeeded -> {:ok, latest}
      status -> {:error, {:attempt_not_runnable, status}}
    end
  end

  defp dispatch(spec, _project, snapshot, %Attempt{status: :succeeded} = attempt) do
    asset = Assets.get_asset!(attempt.result_asset_id)

    {:ok,
     result(
       spec,
       snapshot,
       attempt,
       asset,
       Quality.latest_report(asset.id, :technical),
       Quality.latest_report(asset.id, :semantic)
     )}
  end

  defp dispatch(spec, project, snapshot, %Attempt{status: :prepared} = attempt) do
    with {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      case Fake.submit(snapshot, submitted) do
        {:ok, provider_result} ->
          complete_success(spec, project, snapshot, submitted, provider_result)

        {:error, :provider_rejected, metadata} ->
          complete_error(submitted, :failed, :provider_rejected, metadata)

        {:error, :provider_timeout, metadata} ->
          complete_timeout(project, submitted, metadata)

        {:error, code, metadata} ->
          complete_error(submitted, :failed, code, metadata)
      end
    end
  end

  defp complete_success(spec, project, snapshot, attempt, provider_result) do
    with :ok <- record_callbacks(provider_result),
         {:ok, _actual} <- record_cost(project, attempt, provider_result.cost_micros),
         {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: spec.kind,
             expected_mime: provider_result.mime_type,
             idempotency_key: "attempt:#{attempt.id}:asset"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, provider_result.bytes),
         {:ok, asset} <-
           Assets.finalize(staged, %{
             "origin" => "fake",
             "attempt_id" => attempt.id,
             "provider_request_snapshot_id" => snapshot.id,
             "generation_spec_id" => spec.id,
             "candidate_index" => spec.candidate_index
           }),
         {:ok, technical} <- Quality.run_technical(asset, spec),
         {:ok, semantic} <- maybe_run_semantic(technical, asset, spec),
         {:ok, succeeded} <-
           Generation.transition_attempt(attempt, :succeeded, %{
             external_request_id: provider_result.external_request_id,
             result_asset_id: asset.id,
             response_metadata: %{
               "mime_type" => provider_result.mime_type,
               "width" => provider_result.width,
               "height" => provider_result.height,
               "cost_micros" => provider_result.cost_micros
             }
           }) do
      {:ok, result(spec, snapshot, succeeded, asset, technical, semantic)}
    else
      {:error, reason} ->
        mark_internal_failure(attempt, reason)
        {:error, reason}
    end
  end

  defp complete_error(attempt, target, code, metadata) do
    Generation.transition_attempt(attempt, target, %{
      error_code: to_string(code),
      error_message: to_string(code),
      response_metadata: stringify_keys(metadata)
    })

    {:error, code}
  end

  defp complete_timeout(project, attempt, metadata) do
    estimated = Map.get(metadata, :estimated_cost_micros, 0)
    record_cost(project, attempt, estimated, nil)
    complete_error(attempt, :timed_out, :provider_timeout, metadata)
  end

  defp record_callbacks(provider_result) do
    callbacks = max(1, provider_result.duplicate_callbacks)

    statuses =
      if provider_result.out_of_order_callbacks,
        do: ["completed", "processing"],
        else: ["completed"]

    Enum.each(1..callbacks, fn index ->
      status = Enum.at(statuses, rem(index - 1, length(statuses)))

      Workflow.record_inbox("fake", provider_result.external_request_id, %{
        "status" => status,
        "callback_index" => index
      })
    end)

    :ok
  end

  defp record_cost(project, attempt, amount, actual \\ :estimated) do
    actual_amount = if actual == :estimated, do: amount, else: actual

    with {:ok, _estimate} <-
           Costs.record_estimate(
             project,
             amount,
             "estimate:#{attempt.id}",
             %{provider: "fake"},
             attempt.id
           ),
         {:ok, reservation} <-
           Costs.reserve(project, amount, "reservation:#{attempt.id}", attempt.id),
         {:ok, actual_entry} <- Costs.settle(reservation, actual_amount, %{provider: "fake"}) do
      {:ok, actual_entry}
    end
  end

  defp maybe_run_semantic(%{status: :pass}, asset, spec),
    do: Quality.run_semantic_fixture(asset, spec)

  defp maybe_run_semantic(_technical, _asset, _spec), do: {:ok, nil}

  defp mark_internal_failure(%Attempt{} = attempt, reason) do
    case Repo.get!(Attempt, attempt.id) do
      %Attempt{status: :submitted} = current ->
        Generation.transition_attempt(current, :failed, %{
          error_code: "orchestration_failed",
          error_message: inspect(reason)
        })

      _ ->
        :ok
    end
  end

  defp result(spec, snapshot, attempt, asset, technical, semantic) do
    %{
      spec: spec,
      request_snapshot: snapshot,
      attempt: attempt,
      asset: asset,
      technical_qc: technical,
      semantic_qc: semantic
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
