defmodule Dramatizer.Generation.Adapters.OpenAIImages do
  @moduledoc "Stateless OpenAI Images generation and multipart edit adapter."

  @behaviour Dramatizer.Generation.Adapter

  alias Dramatizer.Assets
  alias Dramatizer.Generation.{Attempt, ProviderRequestSnapshot}

  @default_base_url "https://api.openai.com"
  @default_timeout 180_000

  @impl true
  def submit(snapshot, attempt), do: submit(snapshot, attempt, [])

  def submit(%ProviderRequestSnapshot{} = snapshot, %Attempt{}, opts) do
    with {:ok, api_key} <- fetch_credential(snapshot.credential_ref),
         {:ok, request} <- build_request(snapshot) do
      base_url = Keyword.get(opts, :base_url, @default_base_url)

      common = [
        headers: [{"authorization", "Bearer #{api_key}"}],
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_timeout)
      ]

      request_options =
        common
        |> Keyword.merge(request.options)
        |> Keyword.merge(Keyword.drop(opts, [:base_url, :receive_timeout]))

      case Req.post(base_url <> request.path, request_options) do
        {:ok, response} ->
          handle_response(response, snapshot.request_input["output_format"] || "png")

        {:error, %Req.TransportError{reason: reason}} ->
          map_transport_error(reason)

        {:error, error} ->
          {:error, :provider_unavailable, %{reason: inspect(error)}}
      end
    end
  end

  defp build_request(
         %ProviderRequestSnapshot{request_input: %{"operation" => "generate"}} = snapshot
       ) do
    input = snapshot.request_input

    {:ok,
     %{
       path: "/v1/images/generations",
       options: [
         json: %{
           "model" => snapshot.model,
           "prompt" => Map.fetch!(input, "prompt"),
           "size" => input["size"] || snapshot.params["size"],
           "quality" => input["quality"] || snapshot.params["quality"],
           "output_format" => input["output_format"] || "png"
         }
       ]
     }}
  end

  defp build_request(%ProviderRequestSnapshot{request_input: %{"operation" => "edit"}} = snapshot) do
    input = snapshot.request_input

    with {:ok, images} <- load_assets(Map.fetch!(input, "image_asset_ids")),
         {:ok, mask} <- load_optional_asset(input["mask_asset_id"]) do
      image_fields =
        Enum.map(images, fn asset ->
          {bytes, filename, mime_type} = asset_part(asset)
          {:"image[]", {bytes, filename: filename, content_type: mime_type}}
        end)

      mask_fields =
        case mask do
          nil ->
            []

          asset ->
            {bytes, filename, mime_type} = asset_part(asset)
            [{:mask, {bytes, filename: filename, content_type: mime_type}}]
        end

      fields =
        [
          model: snapshot.model,
          prompt: Map.fetch!(input, "prompt"),
          output_format: input["output_format"] || "png"
        ] ++ image_fields ++ mask_fields

      {:ok, %{path: "/v1/images/edits", options: [form_multipart: fields]}}
    end
  end

  defp build_request(_snapshot), do: {:error, :unsupported_image_operation, %{}}

  defp handle_response(%Req.Response{status: status} = response, format)
       when status in 200..299 do
    mime_type = mime_type(format)

    decoded =
      response.body
      |> Map.get("data", [])
      |> Enum.map(fn item -> Base.decode64(item["b64_json"] || "") end)

    if decoded != [] and Enum.all?(decoded, &match?({:ok, _}, &1)) do
      images = Enum.map(decoded, fn {:ok, bytes} -> %{bytes: bytes, mime_type: mime_type} end)
      request_id = response |> Req.Response.get_header("x-request-id") |> List.first()

      {:ok,
       %{
         images: images,
         request_id: request_id,
         external_request_id: request_id,
         usage: Map.get(response.body, "usage", %{}),
         response_metadata: %{
           "created" => response.body["created"],
           "request_id" => request_id,
           "output_format" => format
         }
       }}
    else
      {:error, :invalid_provider_response, %{status: status}}
    end
  end

  defp handle_response(%Req.Response{status: status} = response, _format) do
    request_id = response |> Req.Response.get_header("x-request-id") |> List.first()
    metadata = %{status: status, request_id: request_id}

    cond do
      status == 429 -> {:error, :rate_limited, metadata}
      status in [408, 504] -> {:error, :provider_timeout, metadata}
      status >= 500 -> {:error, :provider_unavailable, metadata}
      true -> {:error, :provider_rejected, metadata}
    end
  end

  defp load_assets(ids) when is_list(ids) and ids != [] do
    {:ok, Enum.map(ids, &Assets.get_asset!/1)}
  rescue
    Ecto.NoResultsError -> {:error, :reference_asset_not_found, %{}}
  end

  defp load_assets(_ids), do: {:error, :reference_asset_required, %{}}

  defp load_optional_asset(nil), do: {:ok, nil}

  defp load_optional_asset(id) do
    {:ok, Assets.get_asset!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :mask_asset_not_found, %{}}
  end

  defp asset_part(asset) do
    bytes = asset |> Assets.absolute_path() |> File.read!()
    extension = extension(asset.mime_type)
    {bytes, "#{asset.id}.#{extension}", asset.mime_type}
  end

  defp mime_type("jpeg"), do: "image/jpeg"
  defp mime_type("webp"), do: "image/webp"
  defp mime_type(_format), do: "image/png"

  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/webp"), do: "webp"
  defp extension(_mime), do: "png"

  defp fetch_credential(reference) do
    case System.get_env(reference) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_credential, %{credential_ref: reference}}
    end
  end

  defp map_transport_error(reason) when reason in [:timeout, :etimedout],
    do: {:error, :provider_timeout, %{reason: reason}}

  defp map_transport_error(reason),
    do: {:error, :provider_unavailable, %{reason: reason}}
end
