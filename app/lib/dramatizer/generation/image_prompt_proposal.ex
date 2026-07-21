defmodule Dramatizer.Generation.ImagePromptProposal do
  @moduledoc "Creates a persisted AI prompt proposal before deterministic image compilation."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Costs
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Generation.Adapters.OpenAIResponses
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Prompts.Composer
  alias Dramatizer.Repo

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "provider_prompt" => %{"type" => "string", "minLength" => 1}
    },
    "required" => ["provider_prompt"]
  }

  def propose(%Project{} = project, image_task_type, authority, opts \\ [])
      when image_task_type in [:reference_image, :shot_keyframe, :image_edit] and
             is_map(authority) do
    mode = Keyword.get(opts, :provider_mode, Application.fetch_env!(:dramatizer, :provider_mode))
    appendix = Projects.current_prompt_appendix(project, :image_prompt)

    input_json =
      CanonicalJSON.encode(%{
        "image_task_type" => Atom.to_string(image_task_type),
        "chinese_authority" => authority,
        "instruction" => "补足可生成的角色、场景、材质、光照、构图和镜头细节；保留必须项和禁止项。"
      })

    with {:ok, prompt} <- Composer.compose(:image_prompt, appendix, %{input_json: input_json}),
         {:ok, spec} <-
           Generation.create_spec(project, %{
             kind: "image_prompt_proposal",
             formal: false,
             payload: %{
               "image_task_type" => Atom.to_string(image_task_type),
               "chinese_authority_hash" => CanonicalJSON.hash(authority),
               "prompt_content_hash" => prompt.content_hash
             }
           }),
         {:ok, snapshot, _first_attempt} <-
           Generation.prepare_attempt(spec, :image_prompt, project, %{
             node_run_id: Keyword.get(opts, :node_run_id),
             task_override: task_override(mode, Keyword.get(opts, :task_override, %{})),
             request_input: %{
               "input" => prompt.content,
               "schema_name" => "image_prompt_proposal",
               "schema" => @schema,
               "image_task_type" => Atom.to_string(image_task_type),
               "chinese_authority_hash" => CanonicalJSON.hash(authority)
             },
             prompt_snapshot: %{
               "core_version" => prompt.core_version,
               "core_hash" => prompt.core_hash,
               "appendix_revision_id" => prompt.appendix_revision_id,
               "appendix_revision" => prompt.appendix_revision,
               "appendix_hash" => prompt.appendix_hash,
               "content_hash" => prompt.content_hash,
               "schema_hash" => CanonicalJSON.hash(@schema)
             }
           }),
         {:ok, attempt} <- runnable_attempt(snapshot) do
      dispatch(project, snapshot, attempt, mode, opts)
    end
  end

  defp dispatch(_project, snapshot, %Attempt{status: :succeeded} = attempt, _mode, _opts) do
    case attempt.response_metadata["provider_prompt"] do
      value when is_binary(value) and value != "" ->
        {:ok, result(value, snapshot, attempt)}

      _ ->
        {:error, :prompt_proposal_missing_from_succeeded_attempt}
    end
  end

  defp dispatch(project, snapshot, %Attempt{status: :prepared} = attempt, mode, opts) do
    with {:ok, reservation} <- reserve(project, snapshot, attempt, mode),
         {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      submitter = Keyword.get(opts, :submitter, submitter(mode))

      case submitter.(snapshot, submitted) do
        {:ok, provider_result} ->
          complete_success(snapshot, submitted, provider_result, reservation)

        {:error, code, metadata} ->
          settle(reservation, nil, %{provider: Atom.to_string(mode), status: to_string(code)})

          Generation.record_submission_error(submitted, code, metadata, mode)
      end
    end
  end

  defp dispatch(_project, _snapshot, %Attempt{status: status}, _mode, _opts),
    do: {:error, {:prompt_attempt_not_runnable, status}}

  defp complete_success(snapshot, attempt, provider_result, reservation) do
    with %{"provider_prompt" => prompt} when is_binary(prompt) and prompt != "" <-
           provider_result.output,
         :ok <-
           settle(reservation, Map.get(provider_result, :cost_micros), %{
             provider: snapshot.adapter,
             request_id: Map.get(provider_result, :request_id)
           }),
         {:ok, succeeded} <-
           Generation.transition_attempt(attempt, :succeeded, %{
             external_request_id: Map.get(provider_result, :external_request_id),
             response_metadata: %{
               "provider_prompt" => prompt,
               "provider_prompt_hash" => CanonicalJSON.hash_bytes(prompt),
               "request_id" => Map.get(provider_result, :request_id),
               "usage" => Map.get(provider_result, :usage, %{})
             }
           }) do
      {:ok, result(prompt, snapshot, succeeded)}
    else
      _ ->
        settle(reservation, nil, %{provider: snapshot.adapter, status: "invalid_output"})

        Generation.transition_attempt(attempt, :failed, %{
          error_code: "invalid_prompt_proposal",
          error_message: "invalid_prompt_proposal"
        })

        {:error, :invalid_prompt_proposal}
    end
  end

  defp result(prompt, snapshot, attempt) do
    %{
      provider_prompt: prompt,
      provider_prompt_hash: CanonicalJSON.hash_bytes(prompt),
      request_snapshot: snapshot,
      attempt: attempt
    }
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
      status when status in [:failed, :timed_out] ->
        Generation.retry_attempt(latest)

      status when status in [:submitted, :unknown_remote_state] ->
        {:error, :unknown_remote_state}

      _status ->
        {:ok, latest}
    end
  end

  defp reserve(_project, _snapshot, _attempt, :fake), do: {:ok, nil}

  defp reserve(project, snapshot, attempt, :openai) do
    estimate = Map.get(snapshot.params, "estimated_cost_micros", 0)

    with true <- is_integer(estimate) and estimate >= 0,
         {:ok, _estimate} <-
           Costs.record_estimate(
             project,
             estimate,
             "estimate:#{attempt.id}",
             %{provider: "openai", task_type: "image_prompt"},
             attempt.id
           ),
         {:ok, reservation} <-
           Costs.reserve(project, estimate, "reservation:#{attempt.id}", attempt.id) do
      {:ok, reservation}
    else
      false -> {:error, :invalid_cost_estimate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle(nil, _actual, _metadata), do: :ok

  defp settle(reservation, actual, metadata) do
    case Costs.settle(reservation, actual, metadata) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp submitter(:openai), do: &OpenAIResponses.submit/2

  defp submitter(:fake) do
    fn snapshot, _attempt ->
      {:ok,
       %{
         output: %{
           "provider_prompt" => "离线提示词提案：" <> snapshot.request_input["chinese_authority_hash"]
         },
         external_request_id: "fake-image-prompt-#{snapshot.id}",
         request_id: "fake-image-prompt-#{snapshot.id}",
         usage: %{}
       }}
    end
  end

  defp task_override(:openai, override), do: override

  defp task_override(:fake, override) do
    override
    |> Map.new()
    |> Map.merge(%{adapter: "fake", credential_ref: "none", model: "fake-text-v1"})
  end
end
