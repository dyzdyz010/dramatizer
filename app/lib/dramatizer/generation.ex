defmodule Dramatizer.Generation do
  @moduledoc "Immutable generation specs, redacted request snapshots, and append-only Attempts."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.{Attempt, ConfigResolver, GenerationSpec, ProviderRequestSnapshot}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Workflow.NodeRun

  @guard_failures [:worker_exception, :worker_throw, :worker_exit]

  def enqueue_pipeline(%Project{} = project, %GenerationSpec{} = spec, task_type, opts \\ []),
    do: Dramatizer.Generation.Pipeline.enqueue(project, spec, task_type, opts)

  def enqueue_proposal(%Project{} = project, task_type, authority, opts \\ []),
    do: Dramatizer.Generation.Pipeline.enqueue_proposal(project, task_type, authority, opts)

  @secret_key ~r/(authorization|api[-_]?key|access[-_]?token|secret|password)/i
  @allowed_transitions %{
    prepared: [:submitted, :failed, :timed_out, :superseded],
    submitted: [:succeeded, :failed, :timed_out, :unknown_remote_state],
    unknown_remote_state: [:succeeded, :failed],
    succeeded: [],
    failed: [],
    timed_out: [],
    superseded: []
  }

  def create_spec(%Project{id: project_id}, attrs) do
    payload = Map.fetch!(attrs, :payload)

    values =
      attrs
      |> Map.new()
      |> Map.put(:project_id, project_id)
      |> Map.put(:payload_hash, CanonicalJSON.hash(payload))

    changeset = GenerationSpec.create_changeset(%GenerationSpec{}, values)
    candidate_index = Ecto.Changeset.get_field(changeset, :candidate_index)
    formal = Ecto.Changeset.get_field(changeset, :formal)
    kind = Ecto.Changeset.get_field(changeset, :kind)
    payload_hash = Ecto.Changeset.get_field(changeset, :payload_hash)

    Repo.insert(changeset,
      on_conflict: :nothing,
      conflict_target: [:project_id, :kind, :payload_hash, :candidate_index, :formal]
    )

    {:ok,
     Repo.get_by!(GenerationSpec,
       project_id: project_id,
       kind: kind,
       payload_hash: payload_hash,
       candidate_index: candidate_index,
       formal: formal
     )}
  end

  def prepare_attempt(%GenerationSpec{} = spec, task_type, %Project{} = project, options) do
    task_override = Map.get(options, :task_override, %{})

    config =
      case Map.get(options, :resolved_task_config) do
        %{} = resolved -> resolved |> Map.new() |> Map.put(:task_type, task_type)
        nil -> ConfigResolver.resolve(task_type, project, task_override)
      end

    safe_input = options |> Map.fetch!(:request_input) |> redact()

    prompt_snapshot =
      options
      |> Map.get(:prompt_snapshot, %{})
      |> redact()
      |> standardize_prompt_snapshot(config, safe_input)

    request_payload = %{
      "adapter" => config.adapter,
      "credential_ref" => config.credential_ref,
      "model" => config.model,
      "params" => config.params,
      "request_input" => safe_input,
      "prompt_snapshot" => prompt_snapshot,
      "generation_spec_hash" => spec.payload_hash
    }

    request_hash = CanonicalJSON.hash(request_payload)

    snapshot_attrs = %{
      generation_spec_id: spec.id,
      node_run_id: Map.get(options, :node_run_id),
      task_type: Atom.to_string(task_type),
      adapter: config.adapter,
      credential_ref: config.credential_ref,
      model: config.model,
      params: config.params,
      request_input: safe_input,
      prompt_snapshot: prompt_snapshot,
      request_hash: request_hash,
      secrets_excluded: true
    }

    Repo.transaction(fn ->
      %ProviderRequestSnapshot{}
      |> ProviderRequestSnapshot.create_changeset(snapshot_attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:generation_spec_id, :request_hash]
      )

      snapshot =
        Repo.get_by!(ProviderRequestSnapshot,
          generation_spec_id: spec.id,
          request_hash: request_hash
        )

      %Attempt{}
      |> Attempt.create_changeset(%{
        provider_request_snapshot_id: snapshot.id,
        node_run_id: snapshot.node_run_id,
        attempt_number: 1,
        idempotency_key: "attempt:#{snapshot.id}:1"
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:provider_request_snapshot_id, :attempt_number]
      )

      attempt =
        Repo.get_by!(Attempt, provider_request_snapshot_id: snapshot.id, attempt_number: 1)

      {snapshot, attempt}
    end)
    |> case do
      {:ok, {snapshot, attempt}} -> {:ok, snapshot, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition_attempt(attempt, target, attrs \\ %{})

  def transition_attempt(%Attempt{id: id}, target, attrs) do
    Repo.transaction(fn ->
      current = Repo.one!(from attempt in Attempt, where: attempt.id == ^id, lock: "FOR UPDATE")

      if target in Map.fetch!(@allowed_transitions, current.status) do
        now = DateTime.utc_now()

        defaults =
          case target do
            :submitted ->
              %{status: target, submitted_at: now}

            status when status in [:succeeded, :failed, :timed_out, :superseded] ->
              %{status: target, completed_at: now}

            _ ->
              %{status: target}
          end

        safe_attrs = attrs |> Map.new() |> redact_transition_attrs()

        current
        |> Attempt.transition_changeset(Map.merge(defaults, safe_attrs))
        |> Repo.update!()
      else
        Repo.rollback(:invalid_transition)
      end
    end)
    |> unwrap()
  end

  def record_submission_error(%Attempt{} = attempt, code, metadata, provider_mode) do
    {target, normalized_code, message} =
      if provider_mode in [:openai, :resolved] and code == :provider_timeout do
        {
          :unknown_remote_state,
          :unknown_remote_state,
          "provider outcome is unknown after submission timeout"
        }
      else
        {:failed, code, to_string(code)}
      end

    case transition_attempt(attempt, target, %{
           error_code: to_string(normalized_code),
           error_message: message,
           response_metadata: stringify_keys(metadata)
         }) do
      {:ok, _attempt} -> {:error, normalized_code}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def reconcile_guard_failure(%NodeRun{id: node_run_id}, reason, details)
      when reason in @guard_failures and is_map(details) do
    latest_uncertain =
      Repo.one(
        from attempt in Attempt,
          where:
            attempt.node_run_id == ^node_run_id and
              attempt.status in [:submitted, :unknown_remote_state],
          order_by: [desc: attempt.attempt_number, desc: attempt.inserted_at],
          limit: 1
      )

    case latest_uncertain do
      %Attempt{status: :submitted} = attempt ->
        case transition_attempt(attempt, :unknown_remote_state, %{
               error_code: "unknown_remote_state",
               error_message: "provider outcome is unknown after submitted worker interruption",
               response_metadata: %{"failure_kind" => Atom.to_string(reason)}
             }) do
          {:ok, unknown} ->
            {:unknown_remote_state, Map.put(details, "attempt_id", unknown.id)}

          {:error, _transition_reason} ->
            {reason, details}
        end

      %Attempt{status: :unknown_remote_state} = attempt ->
        {:unknown_remote_state, Map.put(details, "attempt_id", attempt.id)}

      nil ->
        {reason, details}
    end
  end

  def reconcile_guard_failure(%NodeRun{}, reason, details), do: {reason, details}

  def retry_attempt(%Attempt{status: status} = attempt) when status in [:failed, :timed_out] do
    Repo.transaction(fn ->
      Repo.one!(
        from snapshot in ProviderRequestSnapshot,
          where: snapshot.id == ^attempt.provider_request_snapshot_id,
          lock: "FOR UPDATE"
      )

      latest_number =
        Repo.one!(
          from item in Attempt,
            where: item.provider_request_snapshot_id == ^attempt.provider_request_snapshot_id,
            select: max(item.attempt_number)
        )

      next_number = latest_number + 1

      %Attempt{}
      |> Attempt.create_changeset(%{
        provider_request_snapshot_id: attempt.provider_request_snapshot_id,
        node_run_id: attempt.node_run_id,
        attempt_number: next_number,
        idempotency_key: "attempt:#{attempt.provider_request_snapshot_id}:#{next_number}"
      })
      |> Repo.insert!()
    end)
    |> unwrap()
  end

  def retry_attempt(%Attempt{}), do: {:error, :attempt_not_retryable}

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if Regex.match?(@secret_key, to_string(key)) do
        {key, "[REDACTED]"}
      else
        {key, redact(item)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value), do: value

  defp standardize_prompt_snapshot(prompt_snapshot, config, request_input) do
    config_hash =
      CanonicalJSON.hash(%{
        "adapter" => config.adapter,
        "credential_ref" => config.credential_ref,
        "model" => config.model,
        "params" => config.params
      })

    prompt_hash = CanonicalJSON.hash(prompt_snapshot)

    prompt_snapshot
    |> Map.put_new("config_hash", config_hash)
    |> Map.put_new("prompt_hash", prompt_hash)
    |> maybe_put_schema_hash(request_input)
  end

  defp maybe_put_schema_hash(prompt_snapshot, %{"schema" => schema}) when is_map(schema),
    do: Map.put_new(prompt_snapshot, "schema_hash", CanonicalJSON.hash(schema))

  defp maybe_put_schema_hash(prompt_snapshot, _request_input), do: prompt_snapshot

  defp redact_transition_attrs(attrs) do
    attrs
    |> Map.update(:response_metadata, %{}, &redact/1)
    |> Map.update(:error_message, nil, &redact_message/1)
  end

  defp redact_message(nil), do: nil

  defp redact_message(message) do
    Regex.replace(~r/Bearer\s+\S+/i, to_string(message), "Bearer [REDACTED]")
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when value in [true, false, nil], do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
