defmodule Dramatizer.Generation.Adapters.OpenAIResponses do
  @moduledoc "Stateless OpenAI Responses adapter for strict structured text outputs."

  @behaviour Dramatizer.Generation.Adapter

  alias Dramatizer.Generation.{Attempt, ProviderRequestSnapshot}

  @default_base_url "https://api.openai.com"
  @default_timeout 120_000

  @impl true
  def submit(snapshot, attempt), do: submit(snapshot, attempt, [])

  def submit(%ProviderRequestSnapshot{} = snapshot, %Attempt{}, opts) do
    with {:ok, api_key} <- fetch_credential(snapshot.credential_ref) do
      input = snapshot.request_input
      schema = Map.fetch!(input, "schema")
      schema_name = Map.fetch!(input, "schema_name")

      body =
        %{
          "model" => snapshot.model,
          "input" => Map.fetch!(input, "input"),
          "store" => false,
          "text" => %{
            "format" => %{
              "type" => "json_schema",
              "name" => schema_name,
              "schema" => schema,
              "strict" => true
            }
          }
        }
        |> maybe_put_reasoning(snapshot.params)

      base_url = Keyword.get(opts, :base_url, @default_base_url)

      request_options =
        [
          json: body,
          headers: [{"authorization", "Bearer #{api_key}"}],
          retry: false,
          receive_timeout: Keyword.get(opts, :receive_timeout, @default_timeout)
        ]
        |> Keyword.merge(Keyword.drop(opts, [:base_url, :receive_timeout]))

      case Req.post(base_url <> "/v1/responses", request_options) do
        {:ok, response} -> handle_response(response)
        {:error, %Req.TransportError{reason: reason}} -> map_transport_error(reason)
        {:error, error} -> {:error, :provider_unavailable, %{reason: inspect(error)}}
      end
    end
  end

  defp handle_response(%Req.Response{status: status} = response) when status in 200..299 do
    with {:ok, output_text} <- extract_output_text(response.body),
         {:ok, output} <- Jason.decode(output_text) do
      request_id = response |> Req.Response.get_header("x-request-id") |> List.first()

      {:ok,
       %{
         output: output,
         raw_output_text: output_text,
         external_request_id: response.body["id"] || request_id,
         request_id: request_id,
         usage: Map.get(response.body, "usage", %{}),
         response_metadata: %{
           "status" => response.body["status"],
           "request_id" => request_id
         }
       }}
    else
      _ -> {:error, :invalid_provider_response, %{status: status}}
    end
  end

  defp handle_response(%Req.Response{status: status} = response) do
    request_id = response |> Req.Response.get_header("x-request-id") |> List.first()
    metadata = %{status: status, request_id: request_id}

    cond do
      status == 429 -> {:error, :rate_limited, metadata}
      status in [408, 504] -> {:error, :provider_timeout, metadata}
      status >= 500 -> {:error, :provider_unavailable, metadata}
      true -> {:error, :provider_rejected, metadata}
    end
  end

  defp extract_output_text(%{"output" => output}) when is_list(output) do
    text =
      output
      |> Enum.flat_map(&Map.get(&1, "content", []))
      |> Enum.find_value(fn
        %{"type" => "output_text", "text" => value} when is_binary(value) -> value
        _ -> nil
      end)

    if text, do: {:ok, text}, else: {:error, :missing_output_text}
  end

  defp extract_output_text(_body), do: {:error, :missing_output}

  defp fetch_credential(reference) do
    case System.get_env(reference) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_credential, %{credential_ref: reference}}
    end
  end

  defp maybe_put_reasoning(body, %{"reasoning" => reasoning}),
    do: Map.put(body, "reasoning", reasoning)

  defp maybe_put_reasoning(body, _params), do: body

  defp map_transport_error(reason) when reason in [:timeout, :etimedout],
    do: {:error, :provider_timeout, %{reason: reason}}

  defp map_transport_error(reason), do: {:error, :provider_unavailable, %{reason: reason}}
end
