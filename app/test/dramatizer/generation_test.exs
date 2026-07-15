defmodule Dramatizer.GenerationTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Generation
  alias Dramatizer.Projects

  test "request snapshots freeze resolved config and redact secret-shaped data" do
    assert {:ok, project} = Projects.create_project(%{name: "生成测试"})

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               candidate_index: 0,
               payload: %{"shot" => "S001"}
             })

    assert {:ok, snapshot, attempt} =
             Generation.prepare_attempt(spec, :episode_candidates, project, %{
               request_input: %{
                 "text" => "安全正文",
                 "authorization" => "Bearer must-not-persist",
                 "nested" => %{"api_key" => "must-not-persist", "value" => 7}
               },
               prompt_snapshot: %{"core_hash" => "core", "appendix_hash" => "appendix"}
             })

    assert snapshot.model == "gpt-5.6-terra"
    assert snapshot.credential_ref == "OPENAI_API_KEY"
    assert snapshot.request_input["authorization"] == "[REDACTED]"
    assert snapshot.request_input["nested"]["api_key"] == "[REDACTED]"
    assert snapshot.request_input["nested"]["value"] == 7
    refute inspect(snapshot) =~ "must-not-persist"
    assert snapshot.secrets_excluded
    assert attempt.status == :prepared
    assert attempt.attempt_number == 1

    assert {:ok, submitted} = Generation.transition_attempt(attempt, :submitted)

    assert {:ok, failed} =
             Generation.transition_attempt(submitted, :failed, %{error_code: "rate_limited"})

    assert {:error, :invalid_transition} = Generation.transition_attempt(failed, :submitted)

    assert {:ok, retry} = Generation.retry_attempt(failed)
    assert retry.id != failed.id
    assert retry.attempt_number == 2
    assert retry.provider_request_snapshot_id == snapshot.id
  end
end
