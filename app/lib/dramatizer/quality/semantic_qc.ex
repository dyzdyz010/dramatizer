defmodule Dramatizer.Quality.SemanticQC do
  @moduledoc "Multimodal, evidence-preserving, non-blocking semantic image evaluation."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Costs
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Adapters.OpenAIResponses
  alias Dramatizer.Generation.{Attempt, GenerationSpec}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality
  alias Dramatizer.Quality.{QualityReport, SelectionDecision}
  alias Dramatizer.Repo

  @dimensions ~w(identity_variant wardrobe location lighting key_props must_forbid composition camera action expression style artifacts)
  @statuses ~w(pass fail warning inconclusive)

  def dimensions, do: @dimensions

  def run(
        %AssetVersion{} = asset,
        %GenerationSpec{} = target_spec,
        %Project{} = project,
        opts \\ []
      ) do
    evaluator = Keyword.get(opts, :evaluator, &OpenAIResponses.submit/2)
    evaluation_key = Keyword.get(opts, :evaluation_key, "default")
    schema = schema()
    content = multimodal_content(asset, target_spec, opts)

    with {:ok, evaluator_spec} <-
           Generation.create_spec(project, %{
             kind: "image_semantic_qc",
             payload: %{
               "target_generation_spec_id" => target_spec.id,
               "asset_version_id" => asset.id,
               "evaluation_key" => evaluation_key
             }
           }),
         {:ok, snapshot, attempt} <-
           Generation.prepare_attempt(evaluator_spec, :semantic_qc, project, %{
             task_override: Keyword.get(opts, :task_override, %{}),
             request_input: %{
               "input" => [%{"role" => "user", "content" => content}],
               "schema_name" => "image_semantic_qc",
               "schema" => schema,
               "target_generation_spec_id" => target_spec.id,
               "target_asset_version_id" => asset.id
             },
             prompt_snapshot: %{
               "quality_schema_hash" => CanonicalJSON.hash(schema),
               "quality_schema_version" => "image-semantic-qc-v1"
             }
           }) do
      dispatch_attempt(asset, target_spec, project, snapshot, attempt, evaluator, evaluation_key)
    end
  end

  defp dispatch_attempt(
         asset,
         target_spec,
         project,
         snapshot,
         %Attempt{status: :prepared} = attempt,
         evaluator,
         evaluation_key
       ) do
    with {:ok, reservation} <-
           Costs.reserve_provider_attempt(project, snapshot, attempt, :openai),
         {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      case evaluator.(snapshot, submitted) do
        {:ok, result} ->
          with :ok <-
                 Costs.settle_provider_attempt(
                   reservation,
                   Map.get(result, :cost_micros),
                   %{provider: snapshot.adapter, request_id: Map.get(result, :request_id)}
                 ) do
            persist_evaluation(asset, target_spec, snapshot, submitted, result, evaluation_key)
          end

        {:error, code, metadata} ->
          Costs.settle_provider_attempt(reservation, nil, %{
            provider: snapshot.adapter,
            status: to_string(code)
          })

          persist_evaluator_failure(
            asset,
            target_spec,
            snapshot,
            submitted,
            code,
            metadata,
            evaluation_key
          )
      end
    end
  end

  defp dispatch_attempt(
         _asset,
         _target_spec,
         _project,
         snapshot,
         %Attempt{status: :succeeded},
         _evaluator,
         _evaluation_key
       ) do
    case Repo.one(
           from report in QualityReport,
             where: report.evaluator_request_snapshot_id == ^snapshot.id,
             order_by: [desc: report.inserted_at],
             limit: 1
         ) do
      %QualityReport{} = report -> {:ok, report}
      nil -> {:error, :semantic_report_missing_for_succeeded_attempt}
    end
  end

  defp dispatch_attempt(
         asset,
         target_spec,
         project,
         snapshot,
         %Attempt{status: status} = attempt,
         evaluator,
         evaluation_key
       )
       when status in [:failed, :timed_out] do
    with {:ok, retry} <- Generation.retry_attempt(attempt) do
      dispatch_attempt(asset, target_spec, project, snapshot, retry, evaluator, evaluation_key)
    end
  end

  defp dispatch_attempt(
         _asset,
         _target_spec,
         _project,
         _snapshot,
         %Attempt{status: status},
         _evaluator,
         _evaluation_key
       ),
       do: {:error, {:semantic_attempt_not_runnable, status}}

  defp persist_evaluation(asset, target_spec, snapshot, attempt, result, evaluation_key) do
    case validate_output(result.output) do
      {:ok, dimensions} ->
        status = aggregate_status(dimensions)

        {:ok, _succeeded} =
          Generation.transition_attempt(attempt, :succeeded, %{
            external_request_id: Map.get(result, :external_request_id),
            response_metadata: %{
              "usage" => Map.get(result, :usage, %{}),
              "semantic_status" => Atom.to_string(status)
            }
          })

        Quality.persist_report(%{
          project_id: asset.project_id,
          asset_version_id: asset.id,
          generation_spec_id: target_spec.id,
          kind: :semantic,
          status: status,
          blocking: false,
          evidence: %{
            "dimensions" => dimensions,
            "evaluator" => "openai_responses",
            "request_snapshot_id" => snapshot.id
          },
          input_hash:
            CanonicalJSON.hash(%{
              "asset_hash" => asset.blob_hash,
              "spec_hash" => target_spec.payload_hash,
              "request_hash" => snapshot.request_hash,
              "evaluation_key" => evaluation_key,
              "dimensions" => dimensions
            }),
          evaluator_request_snapshot_id: snapshot.id
        })

      {:error, errors} ->
        persist_evaluator_failure(
          asset,
          target_spec,
          snapshot,
          attempt,
          :invalid_semantic_output,
          %{validation_errors: errors},
          evaluation_key
        )
    end
  end

  defp persist_evaluator_failure(
         asset,
         target_spec,
         snapshot,
         attempt,
         code,
         metadata,
         evaluation_key
       ) do
    {:ok, _failed} =
      Generation.transition_attempt(attempt, :failed, %{
        error_code: to_string(code),
        error_message: to_string(code),
        response_metadata: stringify(metadata)
      })

    Quality.persist_report(%{
      project_id: asset.project_id,
      asset_version_id: asset.id,
      generation_spec_id: target_spec.id,
      kind: :semantic,
      status: :evaluator_failed,
      blocking: false,
      evidence: %{
        "dimensions" => %{},
        "evaluator" => "openai_responses",
        "error_code" => to_string(code),
        "metadata" => stringify(metadata),
        "request_snapshot_id" => snapshot.id
      },
      input_hash:
        CanonicalJSON.hash(%{
          "asset_hash" => asset.blob_hash,
          "spec_hash" => target_spec.payload_hash,
          "request_hash" => snapshot.request_hash,
          "evaluation_key" => evaluation_key,
          "error" => to_string(code)
        }),
      evaluator_request_snapshot_id: snapshot.id
    })
  end

  defp multimodal_content(asset, spec, opts) do
    references =
      opts
      |> Keyword.get(:reference_assets, [])
      |> Enum.map(&image_content(&1, "reference"))

    neighbors =
      opts
      |> Keyword.get(:selected_neighbors, [])
      |> Enum.flat_map(fn
        {position, %SelectionDecision{status: :active, asset_version_id: asset_id}}
        when position in [:previous, :next] ->
          neighbor = Assets.get_asset!(asset_id)
          [image_content(neighbor, "#{position}_selected_neighbor")]

        _ ->
          []
      end)

    [
      %{
        "type" => "input_text",
        "text" => "对候选图逐维检查。精确 GenerationSpec=#{CanonicalJSON.encode(spec.payload)}"
      },
      image_content(asset, "candidate")
    ] ++ references ++ neighbors
  end

  defp image_content(asset, role) do
    bytes = asset |> Assets.absolute_path() |> File.read!()

    %{
      "type" => "input_image",
      "image_url" => "data:#{asset.mime_type};base64,#{Base.encode64(bytes)}",
      "detail_role" => role,
      "asset_version_id" => asset.id
    }
  end

  defp validate_output(%{"dimensions" => dimensions}) when is_map(dimensions) do
    exact_keys? = Map.keys(dimensions) |> Enum.sort() == Enum.sort(@dimensions)

    valid_values? =
      Enum.all?(@dimensions, fn dimension ->
        case dimensions[dimension] do
          %{
            "status" => status,
            "confidence" => confidence,
            "reason" => reason,
            "advice" => advice
          } = evidence ->
            Map.keys(evidence) |> Enum.sort() ==
              ~w(advice confidence reason status) and
              status in @statuses and is_number(confidence) and confidence >= 0 and
              confidence <= 1 and is_binary(reason) and is_binary(advice)

          _ ->
            false
        end
      end)

    if exact_keys? and valid_values?,
      do: {:ok, dimensions},
      else: {:error, [%{code: :invalid_semantic_dimensions, path: "/dimensions"}]}
  end

  defp validate_output(_output),
    do: {:error, [%{code: :invalid_semantic_output, path: "/"}]}

  defp aggregate_status(dimensions) do
    statuses = dimensions |> Map.values() |> Enum.map(& &1["status"])

    cond do
      "fail" in statuses -> :fail
      "warning" in statuses -> :warning
      "inconclusive" in statuses -> :inconclusive
      true -> :pass
    end
  end

  defp schema do
    :dramatizer
    |> Application.app_dir("priv/quality_schemas/image_semantic_qc.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
