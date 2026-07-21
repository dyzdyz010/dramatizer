defmodule Dramatizer.Analysis do
  @moduledoc "Executes analysis nodes with an initial Attempt and at most two structured repairs."

  import Ecto.Query

  alias Dramatizer.Analysis.{DAG, Fake, Schemas, Validator}
  alias Dramatizer.Analysis.Jobs.AnalysisNodeJob
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Costs
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Generation.Adapters.OpenAIResponses
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Prompts.Composer
  alias Dramatizer.Repo
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.Enqueue
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  @max_attempts 3

  def enqueue(project, source_revision_ids, opts \\ [])

  def enqueue(%Project{} = project, source_revision_ids, _opts)
      when is_list(source_revision_ids) and source_revision_ids != [] do
    with {:ok, run, nodes} <- DAG.start(project, source_revision_ids),
         {:ok, running} <- ensure_running(run),
         :ok <- enqueue_roots(nodes) do
      {:ok, running}
    end
  end

  def enqueue(%Project{}, [], _opts), do: {:error, :source_revision_required}

  def run_node(%NodeRun{} = node, %Project{} = project, fixture_outputs)
      when is_list(fixture_outputs) do
    provider = fn _snapshot, _attempt, index ->
      case Enum.fetch(fixture_outputs, index) do
        {:ok, output} -> {:ok, %{output: output}}
        :error -> {:error, :fixture_output_exhausted, %{}}
      end
    end

    execute_with_state(node, project, provider, :fixture, [])
  end

  def run_node_live(%NodeRun{} = node, %Project{} = project, opts \\ []) do
    submitter = Keyword.get(opts, :submitter, &OpenAIResponses.submit/2)
    provider = fn snapshot, attempt, _index -> submitter.(snapshot, attempt) end
    execute_with_state(node, project, provider, :resolved, opts)
  end

  def perform_node(node, project, mode, opts \\ [])

  def perform_node(%NodeRun{status: :running} = node, %Project{} = project, :fake, _opts) do
    provider = fn _snapshot, _attempt, _index -> {:ok, %{output: Fake.output(node)}} end
    attempt_loop(node, project, provider, :fixture, [], 0, [], [], nil)
  end

  def perform_node(%NodeRun{status: :running} = node, %Project{} = project, :openai, opts) do
    submitter = Keyword.get(opts, :submitter, &OpenAIResponses.submit/2)
    provider = fn snapshot, attempt, _index -> submitter.(snapshot, attempt) end
    attempt_loop(node, project, provider, :resolved, opts, 0, [], [], nil)
  end

  defp execute_with_state(node, project, provider, mode, opts) do
    with {:ok, running} <- Workflow.transition_node(node, :running) do
      case attempt_loop(running, project, provider, mode, opts, 0, [], [], nil) do
        {:ok, result} ->
          Workflow.transition_node(running, :succeeded, %{result: result})

        {:error, code, result} ->
          public_code = public_error_code(code)

          {:ok, failed} =
            Workflow.transition_node(running, :failed, %{
              error_code: to_string(public_code),
              result: result
            })

          {:error, public_code, failed}
      end
    end
  end

  defp attempt_loop(
         node,
         project,
         provider,
         mode,
         opts,
         index,
         snapshot_ids,
         previous_errors,
         previous_output
       )
       when index < @max_attempts do
    task_type = String.to_existing_atom(node.node_key)
    schema = Schemas.fetch!(task_type)
    prompt = compose_prompt!(task_type, node, project)

    spec_payload = %{
      "node_run_id" => node.id,
      "node_run_count" => node.run_count,
      "repair_index" => index,
      "input_hash" => node.input_hash,
      "validation_errors" => stringify(previous_errors)
    }

    request_input = %{
      "input" => request_text(prompt.content, previous_output, previous_errors),
      "schema_name" => Atom.to_string(task_type),
      "schema" => schema,
      "source_revision_ids" => node.input_snapshot["source_revision_ids"],
      "repair_index" => index
    }

    override =
      if mode == :fixture,
        do: %{adapter: "fixture", credential_ref: "none", model: "fixture-analysis-v1"},
        else: Keyword.get(opts, :task_override, %{})

    with {:ok, spec} <-
           Generation.create_spec(project, %{kind: node.node_key, payload: spec_payload}),
         {:ok, snapshot, _first_attempt} <-
           Generation.prepare_attempt(spec, task_type, project, %{
             task_override: override,
             node_run_id: node.id,
             request_input: request_input,
             prompt_snapshot: %{
               "core_version" => prompt.core_version,
               "core_hash" => prompt.core_hash,
               "appendix_revision_id" => prompt.appendix_revision_id,
               "appendix_revision" => prompt.appendix_revision,
               "appendix_hash" => prompt.appendix_hash,
               "content_hash" => prompt.content_hash,
               "schema_version" => Schemas.version(),
               "schema_hash" => CanonicalJSON.hash(schema)
             }
           }) do
      current_snapshot_ids = snapshot_ids ++ [snapshot.id]

      case runnable_attempt(snapshot) do
        {:ok, %Attempt{status: :succeeded} = succeeded} ->
          cached_attempt_result(succeeded, current_snapshot_ids, index)

        {:ok, attempt} ->
          submit_attempt(
            node,
            project,
            provider,
            mode,
            opts,
            index,
            current_snapshot_ids,
            snapshot,
            attempt
          )

        {:error, reason} ->
          node_failure(reason, current_snapshot_ids, [%{code: reason, path: "/"}])
      end
    end
  end

  defp submit_attempt(
         node,
         project,
         provider,
         mode,
         opts,
         index,
         snapshot_ids,
         snapshot,
         attempt
       ) do
    with {:ok, reservation} <- reserve_provider_cost(project, snapshot, attempt, mode),
         {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      case provider.(snapshot, submitted, index) do
        {:ok, provider_result} ->
          with :ok <-
                 Costs.settle_provider_attempt(
                   reservation,
                   Map.get(provider_result, :cost_micros),
                   %{
                     provider: snapshot.adapter,
                     request_id: Map.get(provider_result, :request_id)
                   }
                 ) do
            validate_provider_result(
              node,
              project,
              provider,
              mode,
              opts,
              index,
              snapshot_ids,
              submitted,
              provider_result
            )
          end

        {:error, code, metadata} ->
          Costs.settle_provider_attempt(reservation, nil, %{
            provider: snapshot.adapter,
            status: to_string(code)
          })

          Generation.transition_attempt(submitted, :failed, %{
            error_code: to_string(code),
            error_message: to_string(code),
            response_metadata: stringify(metadata)
          })

          node_failure(code, snapshot_ids, [%{code: code, path: "/"}])
      end
    end
  end

  defp cached_attempt_result(attempt, snapshot_ids, repair_index) do
    case attempt.response_metadata["validated_output"] do
      output when is_map(output) ->
        {:ok,
         %{
           "output" => output,
           "provider_request_snapshot_ids" => snapshot_ids,
           "repair_attempts" => repair_index
         }}

      _missing ->
        node_failure(
          :analysis_output_missing_from_succeeded_attempt,
          snapshot_ids,
          [%{code: :analysis_output_missing_from_succeeded_attempt, path: "/"}]
        )
    end
  end

  defp validate_provider_result(
         node,
         project,
         provider,
         mode,
         opts,
         index,
         snapshot_ids,
         attempt,
         provider_result
       ) do
    output = provider_result.output

    case Validator.validate(String.to_existing_atom(node.node_key), output,
           source_revision_ids: node.input_snapshot["source_revision_ids"],
           known_reference_ids: succeeded_item_ids(node)
         ) do
      {:ok, validated} ->
        {:ok, _succeeded_attempt} =
          Generation.transition_attempt(attempt, :succeeded, %{
            external_request_id: Map.get(provider_result, :external_request_id),
            response_metadata: %{
              "output_hash" => CanonicalJSON.hash(validated),
              "validated_output" => validated,
              "validated" => true,
              "request_id" => Map.get(provider_result, :request_id),
              "usage" => Map.get(provider_result, :usage, %{})
            }
          })

        {:ok,
         %{
           "output" => validated,
           "provider_request_snapshot_ids" => snapshot_ids,
           "repair_attempts" => index
         }}

      {:error, errors} ->
        {:ok, _failed_attempt} =
          Generation.transition_attempt(attempt, :failed, %{
            external_request_id: Map.get(provider_result, :external_request_id),
            error_code: "structured_validation_failed",
            error_message: "structured_validation_failed",
            response_metadata: %{
              "validation_errors" => stringify(errors),
              "request_id" => Map.get(provider_result, :request_id),
              "usage" => Map.get(provider_result, :usage, %{})
            }
          })

        if index + 1 < @max_attempts do
          attempt_loop(
            node,
            project,
            provider,
            mode,
            opts,
            index + 1,
            snapshot_ids,
            errors,
            output
          )
        else
          node_failure(:structured_validation_failed, snapshot_ids, errors)
        end
    end
  end

  defp reserve_provider_cost(_project, _snapshot, _attempt, :fixture), do: {:ok, nil}

  defp reserve_provider_cost(project, snapshot, attempt, :resolved),
    do: Costs.reserve_provider_attempt(project, snapshot, attempt, :openai)

  defp node_failure(code, snapshot_ids, errors),
    do:
      {:error, code,
       %{
         "provider_request_snapshot_ids" => snapshot_ids,
         "validation_errors" => stringify(errors)
       }}

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
      :submitted -> {:error, :unknown_remote_state}
      :unknown_remote_state -> {:error, :unknown_remote_state}
      :succeeded -> {:ok, latest}
      status -> {:error, {:analysis_attempt_not_runnable, status}}
    end
  end

  defp ensure_running(%WorkflowRun{status: :succeeded} = run), do: {:ok, run}
  defp ensure_running(%WorkflowRun{} = run), do: Workflow.mark_run(run, :running)

  defp public_error_code(:structured_validation_failed), do: :structured_validation_failed
  defp public_error_code(_provider_error), do: :provider_failed

  defp enqueue_roots(nodes) do
    nodes
    |> Enum.filter(&(&1.status == :queued and &1.required_parent_keys == []))
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case Enqueue.node(node, AnalysisNodeJob) do
        {:ok, _execution} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compose_prompt!(task_type, node, project) do
    upstream_results =
      if node.required_parent_keys == [] do
        %{}
      else
        Repo.all(
          from parent in NodeRun,
            where:
              parent.workflow_run_id == ^node.workflow_run_id and
                parent.node_key in ^node.required_parent_keys,
            select: {parent.node_key, parent.result}
        )
        |> Map.new()
      end

    input_json =
      CanonicalJSON.encode(%{
        "task_type" => node.node_key,
        "source_revision_ids" => node.input_snapshot["source_revision_ids"],
        "whole_document" => node.input_snapshot["whole_document"],
        "upstream_results" => upstream_results,
        "locator_contract" => %{
          "start_offset" => "zero_based_unicode_character_offset_in_whole_document",
          "end_offset" => "exclusive_zero_based_unicode_character_offset_in_whole_document"
        }
      })

    appendix = Projects.current_prompt_appendix(project, task_type)
    {:ok, prompt} = Composer.compose(task_type, appendix, %{input_json: input_json})
    prompt
  end

  defp succeeded_item_ids(node) do
    Repo.all(
      from parent in NodeRun,
        where:
          parent.workflow_run_id == ^node.workflow_run_id and
            parent.status == :succeeded,
        select: parent.result
    )
    |> Enum.flat_map(&(get_in(&1, ["output", "items"]) || []))
    |> Enum.map(& &1["id"])
  end

  defp request_text(prompt, nil, []), do: prompt

  defp request_text(prompt, previous_output, errors) do
    """
    #{prompt}

    修复上一份结构化输出。不得删除信息或猜测字段；仅按错误路径修复。
    errors=#{Jason.encode!(stringify(errors))}
    previous_output=#{Jason.encode!(previous_output)}
    """
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
