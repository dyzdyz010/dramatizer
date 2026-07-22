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

  def enqueue(%Project{} = project, source_revision_ids, opts)
      when is_list(source_revision_ids) and source_revision_ids != [] do
    result =
      Repo.transaction(fn ->
        with {:ok, run, nodes} <- DAG.start(project, source_revision_ids, opts) do
          current_run = lock_run(run.id)

          case resume_nodes(current_run, nodes) do
            {:ok, resumable_nodes} ->
              with {:ok, running} <- ensure_running(current_run),
                   {:ok, executions} <- enqueue_runnable(resumable_nodes, opts) do
                %{run: running, executions: executions, notifications: []}
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            {:unknown_remote_state, normalized_nodes} ->
              case Workflow.mark_run(current_run, :failed) do
                {:ok, failed_run} ->
                  %{
                    run: failed_run,
                    executions: [],
                    notifications: normalized_nodes,
                    error: :unknown_remote_state
                  }

                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{error: reason, notifications: notifications}} ->
        Enum.each(notifications, &Enqueue.notify/1)
        {:error, reason}

      {:ok, %{run: run, executions: executions}} ->
        Enum.each(executions, &Enqueue.notify(&1.node))
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enqueue(%Project{}, [], _opts), do: {:error, :source_revision_required}

  def retry_node(%NodeRun{id: node_id}, opts \\ []) do
    result =
      Repo.transaction(fn ->
        node_snapshot = Repo.get!(NodeRun, node_id)

        run = lock_run(node_snapshot.workflow_run_id)
        nodes = locked_nodes(run.id)
        node = Enum.find(nodes, &(&1.id == node_id))

        cond do
          run.definition_key != "whole_novel_analysis_v1" ->
            Repo.rollback(:not_analysis_node)

          node.status != :failed ->
            Repo.rollback(:node_not_failed)

          unknown_remote_orphan?(node) ->
            normalized = normalize_unknown_remote_node!(node)

            case Workflow.mark_run(run, :failed) do
              {:ok, _failed_run} -> %{error: :unknown_remote_state, node: normalized}
              {:error, reason} -> Repo.rollback(reason)
            end

          not dependencies_succeeded?(node, nodes) ->
            Repo.rollback(:node_dependencies_incomplete)

          true ->
            with {:ok, queued} <- recover_locked_node(node),
                 {:ok, _running_run} <- Workflow.mark_run(run, :running),
                 {:ok, execution} <-
                   Enqueue.node(queued, AnalysisNodeJob,
                     job_options: Keyword.get(opts, :job_options, []),
                     notify: false
                   ) do
              execution
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    case result do
      {:ok, %{error: reason, node: node}} ->
        Enqueue.notify(node)
        {:error, reason}

      {:ok, execution} ->
        Enqueue.notify(execution.node)
        {:ok, execution.node}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

    attempt_options = %{
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
    }

    attempt_options =
      case Keyword.get(opts, :resolved_task_config) do
        %{} = resolved -> Map.put(attempt_options, :resolved_task_config, resolved)
        _missing -> attempt_options
      end

    with {:ok, spec} <-
           Generation.create_spec(project, %{kind: node.node_key, payload: spec_payload}),
         {:ok, snapshot, _first_attempt} <-
           Generation.prepare_attempt(spec, task_type, project, attempt_options) do
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

          {:error, normalized_code} =
            Generation.record_submission_error(submitted, code, metadata, mode)

          node_failure(normalized_code, snapshot_ids, [%{code: normalized_code, path: "/"}])
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

  defp enqueue_runnable(nodes, opts) do
    nodes
    |> Enum.filter(&(&1.status == :queued and dependencies_succeeded?(&1, nodes)))
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, executions} ->
      case Enqueue.node(node, AnalysisNodeJob,
             job_options: Keyword.get(opts, :job_options, []),
             notify: false
           ) do
        {:ok, execution} -> {:cont, {:ok, [execution | executions]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end)
  end

  defp resume_nodes(%WorkflowRun{status: :succeeded}, nodes), do: {:ok, nodes}

  defp resume_nodes(%WorkflowRun{id: run_id}, _nodes) do
    nodes = locked_nodes(run_id)
    unknown_nodes = Enum.filter(nodes, &unknown_remote_orphan?/1)

    if unknown_nodes == [] do
      Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, recovered} ->
        if recoverable?(node, nodes) do
          case recover_locked_node(node) do
            {:ok, queued} -> {:cont, {:ok, [queued | recovered]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, [node | recovered]}}
        end
      end)
      |> then(fn
        {:ok, recovered} -> {:ok, Enum.reverse(recovered)}
        error -> error
      end)
    else
      normalized = Enum.map(unknown_nodes, &normalize_unknown_remote_node!/1)
      {:unknown_remote_state, normalized}
    end
  end

  defp locked_nodes(run_id) do
    Repo.all(
      from node in NodeRun,
        where: node.workflow_run_id == ^run_id,
        order_by: [asc: node.inserted_at],
        lock: "FOR UPDATE"
    )
  end

  defp lock_run(run_id) do
    Repo.one!(
      from run in WorkflowRun,
        where: run.id == ^run_id,
        lock: "FOR UPDATE"
    )
  end

  defp recoverable?(%NodeRun{status: :failed} = node, nodes),
    do: dependencies_succeeded?(node, nodes)

  defp recoverable?(%NodeRun{status: :running} = node, nodes) do
    (is_nil(node.worker) or is_nil(node.active_job_id)) and dependencies_succeeded?(node, nodes)
  end

  defp recoverable?(%NodeRun{}, _nodes), do: false

  defp unknown_remote_orphan?(%NodeRun{status: :running} = node) do
    (is_nil(node.worker) or is_nil(node.active_job_id)) and
      not is_nil(unknown_remote_attempt(node))
  end

  defp unknown_remote_orphan?(%NodeRun{status: :failed} = node),
    do: node.error_code == "unknown_remote_state" or not is_nil(unknown_remote_attempt(node))

  defp unknown_remote_orphan?(%NodeRun{}), do: false

  defp unknown_remote_attempt(node) do
    Repo.one(
      from attempt in Attempt,
        where:
          attempt.node_run_id == ^node.id and
            attempt.status in [:submitted, :unknown_remote_state],
        order_by: [desc: attempt.inserted_at, desc: attempt.attempt_number],
        limit: 1
    )
  end

  defp normalize_unknown_remote_node!(node) do
    case unknown_remote_attempt(node) do
      nil ->
        node

      attempt ->
        if attempt.status == :submitted do
          {:ok, _unknown} =
            Generation.transition_attempt(attempt, :unknown_remote_state, %{
              error_code: "unknown_remote_state",
              error_message: "provider outcome is unknown after execution ownership was lost"
            })
        end

        case node.status do
          :running ->
            {:ok, failed} =
              Workflow.transition_locked(node, :failed, %{
                error_code: "unknown_remote_state",
                result: %{"attempt_id" => attempt.id}
              })

            failed

          :failed ->
            node
            |> NodeRun.transition_changeset(%{
              status: :failed,
              error_code: "unknown_remote_state",
              result: Map.put(node.result || %{}, "attempt_id", attempt.id)
            })
            |> Repo.update!()
        end
    end
  end

  defp recover_locked_node(node) do
    Workflow.transition_locked(node, :queued, %{
      run_count: node.run_count + 1,
      error_code: nil,
      result: %{},
      worker: nil,
      active_job_id: nil,
      lease_expires_at: nil,
      next_retry_at: nil,
      started_at: nil,
      completed_at: nil
    })
  end

  defp dependencies_succeeded?(%NodeRun{required_parent_keys: []}, _nodes), do: true

  defp dependencies_succeeded?(node, nodes) do
    statuses = Map.new(nodes, &{&1.node_key, &1.status})
    Enum.all?(node.required_parent_keys, &(Map.get(statuses, &1) == :succeeded))
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
