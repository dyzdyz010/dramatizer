defmodule Dramatizer.Sources.Parser do
  @moduledoc "Normalizes complete source documents without structural chunking."

  alias Dramatizer.Media.Worker

  @version "source-parser-v1"
  @text_extensions ~w(.txt)
  @markdown_extensions ~w(.md .markdown)

  def version, do: @version

  def parse(path) when is_binary(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      extension in @text_extensions -> parse_text_file(path, :text)
      extension in @markdown_extensions -> parse_text_file(path, :markdown)
      extension == ".pdf" -> parse_pdf(path)
      true -> {:error, :unsupported_source_type}
    end
  end

  defp parse_text_file(path, format) do
    with {:ok, bytes} <- File.read(path),
         true <- String.valid?(bytes),
         text = normalize(bytes),
         :ok <- require_text(text) do
      {:ok,
       %{
         format: format,
         text: text,
         locators: character_locators(text),
         parser_version: @version
       }}
    else
      false -> {:error, :invalid_utf8}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_pdf(path) do
    case Worker.run(:extract_pdf_text, %{"path" => path}) do
      {:ok, result} ->
        text = normalize(result["text"])

        with :ok <- require_text(text) do
          locators =
            Enum.map(result["pages"], fn page ->
              %{
                "page" => page["page"],
                "start_offset" => page["start_offset"],
                "end_offset" => page["end_offset"]
              }
            end)

          {:ok,
           %{
             format: :pdf,
             text: text,
             locators: locators,
             parser_version: @version
           }}
        end

      {:error, %{code: "text_layer_required"}} ->
        {:error, :text_layer_required}

      {:error, %{code: "file_not_found"}} ->
        {:error, :file_not_found}

      {:error, %{code: code}} ->
        {:error, stable_error(code)}
    end
  end

  defp normalize(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: normalize(rest)

  defp normalize(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp require_text(text) do
    if String.trim(text) == "", do: {:error, :text_layer_required}, else: :ok
  end

  defp character_locators(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(0, fn {line, line_number}, offset ->
      end_offset = offset + String.length(line)

      locator = %{
        "kind" => "character",
        "line" => line_number,
        "start_offset" => offset,
        "end_offset" => end_offset
      }

      {locator, end_offset + 1}
    end)
    |> elem(0)
  end

  defp stable_error("invalid_pdf"), do: :invalid_pdf
  defp stable_error(_code), do: :source_parse_failed
end
