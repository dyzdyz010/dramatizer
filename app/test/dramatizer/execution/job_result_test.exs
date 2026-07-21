defmodule Dramatizer.Execution.JobResultTest do
  use ExUnit.Case, async: true

  alias Dramatizer.Execution.JobResult

  test "classifies retryable infrastructure and provider failures" do
    assert JobResult.classify(:provider_timeout) == {:retryable, "provider_timeout"}

    assert JobResult.classify(:provider_unavailable) ==
             {:retryable, "provider_unavailable"}

    assert JobResult.classify(:rate_limited) == {:retryable, "provider_rate_limited"}

    assert JobResult.classify(:media_worker_unavailable) ==
             {:retryable, "media_worker_unavailable"}

    assert JobResult.classify(:media_worker_timeout) ==
             {:retryable, "media_worker_timeout"}

    assert JobResult.classify({:http_status, 429}) == {:retryable, "provider_rate_limited"}
    assert JobResult.classify({:http_status, 503}) == {:retryable, "provider_unavailable"}
    assert JobResult.classify(:temporary_file_lock) == {:retryable, "temporary_file_lock"}
  end

  test "classifies permanent, unknown-remote, and cancelled outcomes" do
    assert JobResult.classify(:invalid_proposal_output) ==
             {:permanent, "invalid_proposal_output"}

    assert JobResult.classify(:unknown_remote_state) ==
             {:unknown_remote, "unknown_remote_state"}

    assert JobResult.classify(:cancelled) == {:cancelled, "cancelled"}
  end

  test "sanitizes and bounds unexpected failure codes" do
    secret = "Bearer sk-secret-value"
    {:permanent, code} = JobResult.classify({:unexpected, secret, String.duplicate("x", 500)})

    refute code =~ "sk-secret-value"
    assert code =~ "[REDACTED]"
    assert byte_size(code) <= 200
  end
end
