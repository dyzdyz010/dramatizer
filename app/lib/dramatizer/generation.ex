defmodule Dramatizer.Generation do
  @moduledoc "Immutable generation specs, redacted request snapshots, and append-only Attempts."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.{Attempt, ConfigResolver, GenerationSpec, ProviderRequestSnapshot}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo

  @secret_key ~r/(authorization|api[-_]?key|access[-_]?token|secret|password)/i
  @allowed_transitions %{
    prepared: [:submitted, :failed, :timed_out],
    submitted: [:succeeded, :failed, :timed_out, :unknown_remote_state],
    unknown_remote_state: [:succeeded, :failed],
    succeeded: [],
    failed: [],
    timed_out: []
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
    config = ConfigResolver.resolve(task_type, project, task_override)
    safe_input = options |> Map.fetch!(:request_input) |> redact()
    prompt_snapshot = options |> Map.get(:prompt_snapshot, %{}) |> redact()

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

            status when status in [:succeeded, :failed, :timed_out] ->
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

  defp redact_transition_attrs(attrs) do
    attrs
    |> Map.update(:response_metadata, %{}, &redact/1)
    |> Map.update(:error_message, nil, &redact_message/1)
  end

  defp redact_message(nil), do: nil

  defp redact_message(message) do
    Regex.replace(~r/Bearer\s+\S+/i, to_string(message), "Bearer [REDACTED]")
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
