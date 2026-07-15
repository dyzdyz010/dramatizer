defmodule Dramatizer.Quality.TechnicalQC do
  @moduledoc "Live media integrity and hard technical selection gates."

  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Media.Worker
  alias Dramatizer.Quality

  def run(%AssetVersion{} = asset, %GenerationSpec{} = spec) do
    integrity = Assets.verify(asset)
    probe = Worker.run(:probe_image, %{"path" => Assets.absolute_path(asset)})
    observed = probe_value(probe)
    width = observed["width"]
    height = observed["height"]
    format = observed["format"] |> to_string() |> String.downcase()
    payload = spec.payload

    checks = %{
      "blob_integrity" => check(integrity == :ok, inspect(integrity)),
      "decodable" => check(match?({:ok, _}, probe), probe_reason(probe)),
      "format" =>
        check(format_valid?(asset.mime_type, format, payload["allowed_formats"]), format),
      "exact_dimensions" =>
        check(
          exact_dimensions?(width, height, payload["width"], payload["height"]),
          "#{inspect({width, height})} != #{inspect({payload["width"], payload["height"]})}"
        ),
      "aspect" =>
        check(
          aspect_valid?(width, height, payload),
          "observed=#{inspect({width, height})}"
        ),
      "minimum_dimensions" =>
        check(
          minimum_dimensions?(
            width,
            height,
            payload["minimum_width"],
            payload["minimum_height"]
          ),
          "observed=#{inspect({width, height})}"
        )
    }

    failed = Enum.any?(checks, fn {_key, evidence} -> evidence["status"] == "fail" end)

    Quality.persist_report(%{
      project_id: asset.project_id,
      asset_version_id: asset.id,
      generation_spec_id: spec.id,
      kind: :technical,
      status: if(failed, do: :fail, else: :pass),
      blocking: failed,
      evidence: %{
        "checks" => checks,
        "observed" => observed,
        "probe_error" => if(match?({:error, _}, probe), do: probe_reason(probe), else: nil)
      },
      input_hash:
        CanonicalJSON.hash(%{
          "asset_hash" => asset.blob_hash,
          "spec_hash" => spec.payload_hash,
          "integrity" => inspect(integrity),
          "probe" => stringify_probe(probe),
          "checks" => checks
        })
    })
  end

  defp probe_value({:ok, value}), do: value
  defp probe_value({:error, _error}), do: %{}

  defp probe_reason({:ok, _value}), do: nil
  defp probe_reason({:error, error}), do: inspect(error)

  defp stringify_probe({:ok, value}), do: %{"ok" => value}
  defp stringify_probe({:error, error}), do: %{"error" => inspect(error)}

  defp format_valid?(_mime, "", _allowed), do: false

  defp format_valid?(mime, format, allowed) do
    allowed =
      if is_list(allowed) and allowed != [],
        do: Enum.map(allowed, &String.downcase/1),
        else: [format]

    format in allowed and mime_matches?(mime, format)
  end

  defp mime_matches?("image/png", "png"), do: true
  defp mime_matches?("image/jpeg", format) when format in ["jpeg", "jpg"], do: true
  defp mime_matches?("image/webp", "webp"), do: true
  defp mime_matches?(_mime, _format), do: false

  defp exact_dimensions?(_width, _height, nil, nil), do: true

  defp exact_dimensions?(width, height, expected_width, expected_height)
       when is_integer(width) and is_integer(height) and is_integer(expected_width) and
              is_integer(expected_height),
       do: width == expected_width and height == expected_height

  defp exact_dimensions?(_width, _height, _expected_width, _expected_height), do: false

  defp aspect_valid?(width, height, payload)
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    expected_width = payload["aspect_width"] || payload["width"]
    expected_height = payload["aspect_height"] || payload["height"]

    if is_integer(expected_width) and expected_width > 0 and is_integer(expected_height) and
         expected_height > 0 do
      expected = expected_width / expected_height
      observed = width / height
      tolerance = payload["aspect_tolerance"] || 0.0
      abs(observed - expected) <= tolerance
    else
      true
    end
  end

  defp aspect_valid?(_width, _height, _payload), do: false

  defp minimum_dimensions?(width, height, minimum_width, minimum_height)
       when is_integer(width) and is_integer(height) do
    width >= (minimum_width || 1) and height >= (minimum_height || 1)
  end

  defp minimum_dimensions?(_width, _height, _minimum_width, _minimum_height), do: false

  defp check(true, _reason), do: %{"status" => "pass"}
  defp check(false, reason), do: %{"status" => "fail", "reason" => reason}
end
