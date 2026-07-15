defmodule Dramatizer.Generation.Adapters.Fake do
  @moduledoc "Deterministic offline adapter with explicit recovery fault injection."

  @behaviour Dramatizer.Generation.Adapter

  alias Dramatizer.Generation.{Attempt, ProviderRequestSnapshot}
  alias Dramatizer.Media.Worker

  @default_cost_micros 10

  @impl true
  def submit(%ProviderRequestSnapshot{} = snapshot, %Attempt{} = attempt) do
    input = stringify_keys(snapshot.request_input)
    spec = Map.get(input, "generation_spec", %{}) |> stringify_keys()
    fault = Map.get(input, "fault_profile", %{}) |> stringify_keys()
    delay_ms = integer(fault["delay_ms"], 0)

    if delay_ms > 0, do: Process.sleep(delay_ms)

    cond do
      integer(fault["fail_on_attempt"], -1) == attempt.attempt_number ->
        {:error, :provider_rejected, error_metadata(fault)}

      integer(fault["timeout_on_attempt"], -1) == attempt.attempt_number ->
        {:error, :provider_timeout, error_metadata(fault)}

      true ->
        generate(snapshot, attempt, spec, fault)
    end
  end

  defp generate(snapshot, attempt, spec, fault) do
    width = integer(spec["width"], 540)
    height = integer(spec["height"], 960)
    seed = "#{snapshot.request_hash}:#{attempt.attempt_number}"

    with {:ok, result} <-
           Worker.run(:generate_fake_image, %{
             "width" => width,
             "height" => height,
             "seed" => seed
           }),
         {:ok, bytes} <- Base.decode64(result["png_base64"]) do
      external_id = "fake-#{String.slice(snapshot.request_hash, 0, 16)}-#{attempt.attempt_number}"

      {:ok,
       %{
         bytes: bytes,
         mime_type: "image/png",
         width: result["width"],
         height: result["height"],
         cost_micros: integer(fault["cost_micros"], @default_cost_micros),
         external_request_id: external_id,
         duplicate_callbacks: integer(fault["duplicate_callbacks"], 1),
         out_of_order_callbacks: truthy?(fault["out_of_order_callbacks"])
       }}
    else
      {:error, %{code: code} = error} ->
        {:error, :media_worker_failed, Map.put(error, :error_code, code)}

      :error ->
        {:error, :invalid_fake_image, %{error_code: "invalid_base64"}}
    end
  end

  defp error_metadata(fault) do
    %{estimated_cost_micros: integer(fault["cost_micros"], @default_cost_micros)}
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_value, default), do: default
  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
