defmodule Dramatizer.Generation.Orchestrator do
  @moduledoc "Runs Fake and real providers through one persisted generation contract."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Costs
  alias Dramatizer.Generation

  alias Dramatizer.Generation.{
    Attempt,
    ConfigResolver,
    GenerationSpec,
    ImagePromptCompiler,
    ImagePromptProposal
  }

  alias Dramatizer.Generation.Adapters.{Fake, OpenAIImages, OpenAIResponses}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality
  alias Dramatizer.Repo
  alias Dramatizer.Revisions.Revision
  alias Dramatizer.Workflow

  def generate(spec, task_type, project, opts \\ [])

  def generate(%GenerationSpec{} = spec, task_type, %Project{} = project, opts) do
    with {:ok, context} <- prepare_context(spec, task_type, project, opts),
         {:ok, snapshot, _first_attempt} <-
           Generation.prepare_attempt(spec, task_type, project, context.prepare_options),
         {:ok, attempt} <- runnable_attempt(snapshot),
         result <- dispatch(spec, project, snapshot, attempt, context) do
      result
    end
  end

  defp prepare_context(spec, task_type, project, opts) do
    case Keyword.get(opts, :provider_mode, Application.fetch_env!(:dramatizer, :provider_mode)) do
      :fake -> {:ok, fake_context(spec, opts)}
      :openai -> openai_context(spec, task_type, project, opts)
      mode -> {:error, {:unsupported_provider_mode, mode}}
    end
  end

  defp fake_context(spec, opts) do
    fault_profile = opts |> Keyword.get(:fault_profile, %{}) |> stringify_keys()

    %{
      provider: :fake,
      reference_assets: Keyword.get(opts, :reference_assets, []),
      opts: opts,
      prepare_options: %{
        task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
        request_input: %{
          "generation_spec" => spec.payload,
          "fault_profile" => fault_profile
        },
        prompt_snapshot: Keyword.get(opts, :prompt_snapshot, %{})
      }
    }
  end

  defp openai_context(spec, task_type, project, opts) do
    task_override = Keyword.get(opts, :task_override, %{})
    config = ConfigResolver.resolve(task_type, project, task_override)

    with {:ok, reference_assets} <- resolve_reference_assets(spec, opts),
         {:ok, proposal} <- resolve_prompt_proposal(project, task_type, spec, opts),
         {:ok, compilation} <-
           ImagePromptCompiler.compile(task_type, spec.payload,
             revision_ids: revision_ids(spec),
             reference_asset_ids: Enum.map(reference_assets, & &1.id),
             user_instruction: proposal.provider_prompt
           ) do
      reference_ids = Enum.map(reference_assets, & &1.id)
      operation = if reference_ids == [], do: "generate", else: "edit"

      request_input = %{
        "operation" => operation,
        "prompt" => compilation.provider_prompt,
        "image_asset_ids" => reference_ids,
        "mask_asset_id" => nil,
        "size" => config.params["size"],
        "quality" => config.params["quality"],
        "output_format" => "png",
        "formal" => spec.formal
      }

      {:ok,
       %{
         provider: :openai,
         reference_assets: reference_assets,
         opts: opts,
         prepare_options: %{
           task_override: task_override,
           request_input: request_input,
           prompt_snapshot: %{
             "compiler_version" => compilation.compiler_version,
             "chinese_authority" => compilation.chinese_authority,
             "chinese_authority_hash" => compilation.chinese_authority_hash,
             "provider_prompt_hash" => compilation.provider_prompt_hash,
             "proposal_request_snapshot_id" => proposal.request_snapshot_id,
             "proposal_attempt_id" => proposal.attempt_id,
             "proposal_prompt_hash" => proposal.provider_prompt_hash,
             "links" => compilation.links
           }
         }
       }}
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

  defp dispatch(spec, _project, snapshot, %Attempt{status: :succeeded} = attempt, _context) do
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

  defp dispatch(spec, project, snapshot, %Attempt{status: :prepared} = attempt, context) do
    with {:ok, context} <- reserve_provider_cost(project, snapshot, attempt, context),
         {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      case submit(snapshot, submitted, context) do
        {:ok, provider_result} ->
          complete_success(spec, project, snapshot, submitted, provider_result, context)

        {:error, :provider_timeout, metadata} ->
          settle_provider_cost(context, nil, %{status: "provider_timeout"})
          complete_timeout(project, submitted, metadata, context.provider)

        {:error, code, metadata} ->
          settle_provider_cost(context, nil, %{status: to_string(code)})
          complete_error(submitted, :failed, code, metadata)
      end
    end
  end

  defp submit(snapshot, attempt, %{provider: :fake}), do: Fake.submit(snapshot, attempt)

  defp submit(snapshot, attempt, %{provider: :openai, opts: opts}) do
    submitter = Keyword.get(opts, :image_submitter, &OpenAIImages.submit/2)
    submitter.(snapshot, attempt)
  end

  defp complete_success(
         spec,
         project,
         snapshot,
         attempt,
         provider_result,
         %{provider: :fake} = context
       ) do
    with :ok <- record_callbacks(provider_result),
         {:ok, _actual} <-
           record_cost(project, attempt, provider_result.cost_micros, :estimated, "fake"),
         {:ok, completed} <-
           persist_image(
             spec,
             project,
             snapshot,
             attempt,
             %{
               bytes: provider_result.bytes,
               mime_type: provider_result.mime_type,
               external_request_id: provider_result.external_request_id,
               usage: %{},
               request_id: provider_result.external_request_id,
               response_metadata: %{
                 "width" => provider_result.width,
                 "height" => provider_result.height,
                 "cost_micros" => provider_result.cost_micros
               }
             },
             context.reference_assets,
             quality_options(context)
           ) do
      {:ok, completed}
    else
      {:error, reason} ->
        mark_internal_failure(attempt, reason)
        {:error, reason}
    end
  end

  defp complete_success(spec, project, snapshot, attempt, provider_result, context) do
    case Map.get(provider_result, :images, []) do
      [%{bytes: bytes, mime_type: mime_type}] ->
        cost_micros = Map.get(provider_result, :cost_micros)

        with :ok <-
               settle_provider_cost(context, cost_micros, %{
                 provider: "openai",
                 request_id: Map.get(provider_result, :request_id)
               }),
             qc_opts <- quality_options(context),
             {:ok, completed} <-
               persist_image(
                 spec,
                 project,
                 snapshot,
                 attempt,
                 %{
                   bytes: bytes,
                   mime_type: mime_type,
                   external_request_id: Map.get(provider_result, :external_request_id),
                   usage: Map.get(provider_result, :usage, %{}),
                   request_id: Map.get(provider_result, :request_id),
                   response_metadata: Map.get(provider_result, :response_metadata, %{}),
                   cost_micros: cost_micros
                 },
                 context.reference_assets,
                 qc_opts
               ) do
          {:ok, completed}
        else
          {:error, reason} ->
            mark_internal_failure(attempt, reason)
            {:error, reason}
        end

      images ->
        reason = {:invalid_image_count, length(images)}
        mark_internal_failure(attempt, reason)
        {:error, reason}
    end
  end

  defp persist_image(
         spec,
         project,
         snapshot,
         attempt,
         provider_result,
         reference_assets,
         qc_opts
       ) do
    with {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: spec.kind,
             expected_mime: provider_result.mime_type,
             idempotency_key: "attempt:#{attempt.id}:asset"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, provider_result.bytes),
         {:ok, asset} <-
           Assets.finalize(staged, %{
             "origin" => snapshot.adapter,
             "attempt_id" => attempt.id,
             "provider_request_snapshot_id" => snapshot.id,
             "provider_request_id" => provider_result.request_id,
             "generation_spec_id" => spec.id,
             "candidate_index" => spec.candidate_index,
             "reference_asset_ids" => Enum.map(reference_assets, & &1.id),
             "parent_asset_id" => spec.payload["parent_asset_id"],
             "mask_asset_id" => spec.payload["mask_asset_id"],
             "formal" => spec.formal
           }),
         {:ok, qc} <- finalize_quality(asset, spec, project, qc_opts),
         {:ok, succeeded} <-
           Generation.transition_attempt(attempt, :succeeded, %{
             external_request_id: provider_result.external_request_id,
             result_asset_id: asset.id,
             response_metadata: %{
               "mime_type" => provider_result.mime_type,
               "request_id" => provider_result.request_id,
               "usage" => provider_result.usage,
               "cost_micros" => Map.get(provider_result, :cost_micros),
               "provider" => stringify_keys(provider_result.response_metadata)
             }
           }) do
      {:ok, result(spec, snapshot, succeeded, asset, qc.technical, qc.semantic)}
    end
  end

  defp quality_options(context) do
    [reference_assets: context.reference_assets]
    |> maybe_put_option(:defer_quality, Keyword.get(context.opts, :defer_quality))
    |> maybe_put_option(:selected_neighbors, Keyword.get(context.opts, :selected_neighbors))
    |> maybe_put_option(:evaluator, Keyword.get(context.opts, :semantic_evaluator))
  end

  defp finalize_quality(asset, spec, project, opts) do
    if Keyword.get(opts, :defer_quality, false) do
      {:ok, %{technical: nil, semantic: nil}}
    else
      Quality.after_finalize(asset, spec, project, Keyword.delete(opts, :defer_quality))
    end
  end

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)

  defp complete_error(attempt, target, code, metadata) do
    Generation.transition_attempt(attempt, target, %{
      error_code: to_string(code),
      error_message: to_string(code),
      response_metadata: stringify_keys(metadata)
    })

    {:error, code}
  end

  defp complete_timeout(project, attempt, metadata, :fake) do
    estimated = Map.get(metadata, :estimated_cost_micros, 0)
    record_cost(project, attempt, estimated, nil, "fake")
    complete_error(attempt, :timed_out, :provider_timeout, metadata)
  end

  defp complete_timeout(_project, attempt, metadata, :openai) do
    Generation.record_submission_error(attempt, :provider_timeout, metadata, :openai)
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

  defp record_cost(project, attempt, amount, actual, provider) do
    actual_amount = if actual == :estimated, do: amount, else: actual

    with {:ok, _estimate} <-
           Costs.record_estimate(
             project,
             amount,
             "estimate:#{attempt.id}",
             %{provider: provider},
             attempt.id
           ),
         {:ok, reservation} <-
           Costs.reserve(project, amount, "reservation:#{attempt.id}", attempt.id),
         {:ok, actual_entry} <-
           Costs.settle(reservation, actual_amount, %{provider: provider}) do
      {:ok, actual_entry}
    end
  end

  defp reserve_provider_cost(_project, _snapshot, _attempt, %{provider: :fake} = context),
    do: {:ok, context}

  defp reserve_provider_cost(project, snapshot, attempt, %{provider: :openai} = context) do
    estimate = Map.get(snapshot.params, "estimated_cost_micros", 0)

    with true <- is_integer(estimate) and estimate >= 0,
         {:ok, _entry} <-
           Costs.record_estimate(
             project,
             estimate,
             "estimate:#{attempt.id}",
             %{provider: "openai", task_type: snapshot.task_type},
             attempt.id
           ),
         {:ok, reservation} <-
           Costs.reserve(project, estimate, "reservation:#{attempt.id}", attempt.id) do
      {:ok, Map.put(context, :cost_reservation, reservation)}
    else
      false -> {:error, :invalid_cost_estimate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_provider_cost(%{provider: :fake}, _actual, _metadata), do: :ok

  defp settle_provider_cost(%{cost_reservation: reservation}, actual, metadata) do
    case Costs.settle(reservation, actual, metadata) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_reference_assets(spec, opts) do
    case Keyword.fetch(opts, :reference_assets) do
      {:ok, assets} when is_list(assets) ->
        {:ok, Enum.uniq_by(assets, & &1.id)}

      _ ->
        reference_revision_id =
          get_in(spec.payload, ["dependencies", "reference_set_revision_id"])

        case reference_revision_id && Repo.get(Revision, reference_revision_id) do
          %Revision{kind: :reference_set, payload: payload} ->
            assets =
              payload
              |> Map.get("primary_assets", %{})
              |> Map.values()
              |> Enum.uniq()
              |> Enum.map(&Assets.get_asset!/1)

            {:ok, assets}

          _ ->
            {:ok, []}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :reference_asset_not_found}
  end

  defp resolve_prompt_proposal(project, task_type, spec, opts) do
    case Keyword.get(opts, :prompt_proposal) do
      %{
        provider_prompt: provider_prompt,
        provider_prompt_hash: provider_prompt_hash,
        request_snapshot_id: request_snapshot_id,
        attempt_id: attempt_id
      }
      when is_binary(provider_prompt) and is_binary(provider_prompt_hash) and
             is_binary(request_snapshot_id) and is_binary(attempt_id) ->
        {:ok,
         %{
           provider_prompt: provider_prompt,
           provider_prompt_hash: provider_prompt_hash,
           request_snapshot_id: request_snapshot_id,
           attempt_id: attempt_id
         }}

      nil ->
        with {:ok, proposal} <-
               ImagePromptProposal.propose(project, task_type, spec.payload,
                 provider_mode: :openai,
                 submitter: Keyword.get(opts, :prompt_submitter, &OpenAIResponses.submit/2),
                 task_override: Keyword.get(opts, :prompt_task_override, %{})
               ) do
          {:ok,
           %{
             provider_prompt: proposal.provider_prompt,
             provider_prompt_hash: proposal.provider_prompt_hash,
             request_snapshot_id: proposal.request_snapshot.id,
             attempt_id: proposal.attempt.id
           }}
        end

      _invalid ->
        {:error, :invalid_prompt_proposal}
    end
  end

  defp revision_ids(spec) do
    dependency_ids =
      spec.payload
      |> Map.get("dependencies", %{})
      |> Map.values()
      |> Enum.filter(&is_binary/1)

    [spec.revision_id | dependency_ids]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

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
