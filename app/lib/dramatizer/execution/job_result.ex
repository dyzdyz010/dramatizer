defmodule Dramatizer.Execution.JobResult do
  @moduledoc "Classifies worker failures without leaking sensitive provider data."

  @maximum_code_bytes 200

  def classify(reason)

  def classify(reason)
      when reason in [
             :provider_timeout,
             :provider_unavailable,
             :network_error,
             :temporary_file_lock,
             :media_worker_unavailable,
             :media_worker_timeout,
             :media_worker_failed
           ],
      do: {:retryable, Atom.to_string(reason)}

  def classify(:rate_limited), do: {:retryable, "provider_rate_limited"}

  def classify({:http_status, 429}), do: {:retryable, "provider_rate_limited"}

  def classify({:http_status, status}) when status in 500..599,
    do: {:retryable, "provider_unavailable"}

  def classify(:unknown_remote_state), do: {:unknown_remote, "unknown_remote_state"}
  def classify(:cancelled), do: {:cancelled, "cancelled"}
  def classify(reason) when is_atom(reason), do: {:permanent, Atom.to_string(reason)}

  def classify(reason), do: {:permanent, sanitize(reason)}

  defp sanitize(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 400)
    |> redact()
    |> truncate(@maximum_code_bytes)
  end

  defp redact(value) do
    Regex.replace(~r/Bearer\s+\S+/i, value, "Bearer [REDACTED]")
  end

  defp truncate(value, maximum) when byte_size(value) <= maximum, do: value

  defp truncate(value, maximum) do
    candidate = binary_part(value, 0, maximum)

    if String.valid?(candidate), do: candidate, else: truncate(value, maximum - 1)
  end
end
