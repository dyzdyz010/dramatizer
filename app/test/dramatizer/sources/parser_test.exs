defmodule Dramatizer.Sources.ParserTest do
  use ExUnit.Case, async: true

  alias Dramatizer.Sources.Parser

  test "normalizes UTF-8 BOM and newlines while retaining character locators" do
    path = temporary_path("bom.txt")
    File.write!(path, <<0xEF, 0xBB, 0xBF>> <> "第一章\r\n你好\r")

    assert {:ok, parsed} = Parser.parse(path)
    assert parsed.format == :text
    assert parsed.text == "第一章\n你好\n"

    assert [first, second | _] = parsed.locators
    assert first == %{"kind" => "character", "line" => 1, "start_offset" => 0, "end_offset" => 3}
    assert second == %{"kind" => "character", "line" => 2, "start_offset" => 4, "end_offset" => 6}
  end

  test "preserves Markdown content without interpreting chapter structure" do
    path = fixture_path("novel.md")
    expected = path |> File.read!() |> String.replace("\r\n", "\n")

    assert {:ok, parsed} = Parser.parse(path)
    assert parsed.format == :markdown
    assert parsed.text == expected
    assert String.contains?(parsed.text, "**车站**")
    assert String.contains?(parsed.text, "> 远处")
  end

  test "extracts text-layer PDFs with exact page locators" do
    path = temporary_path("text.pdf")
    File.write!(path, pdf(["Page one", "Second page"]))

    assert {:ok, parsed} = Parser.parse(path)
    assert parsed.format == :pdf
    assert parsed.text == "Page one\nSecond page"

    assert parsed.locators == [
             %{"page" => 1, "start_offset" => 0, "end_offset" => 8},
             %{"page" => 2, "start_offset" => 9, "end_offset" => 20}
           ]
  end

  test "rejects image-only PDFs without attempting OCR" do
    path = temporary_path("image_only.pdf")
    File.write!(path, pdf([nil]))

    assert {:error, :text_layer_required} = Parser.parse(path)
  end

  defp fixture_path(name), do: Path.expand("../../support/fixtures/sources/#{name}", __DIR__)

  defp temporary_path(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-source-#{System.unique_integer([:positive])}-#{name}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp pdf(page_texts) do
    page_count = length(page_texts)
    font_id = 3 + page_count

    page_objects =
      page_texts
      |> Enum.with_index(3)
      |> Enum.flat_map(fn {text, page_id} ->
        content_id = font_id + page_id - 2

        page =
          if text do
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " <>
              "/Resources << /Font << /F1 #{font_id} 0 R >> >> /Contents #{content_id} 0 R >>"
          else
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"
          end

        content =
          if text do
            escaped =
              text
              |> String.replace("\\", "\\\\")
              |> String.replace("(", "\\(")
              |> String.replace(")", "\\)")

            stream = "BT /F1 12 Tf 72 720 Td (#{escaped}) Tj ET"

            [
              {page_id, page},
              {content_id, "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"}
            ]
          else
            [{page_id, page}]
          end

        content
      end)

    kids = Enum.map_join(3..(2 + page_count), " ", &"#{&1} 0 R")

    objects =
      [
        {1, "<< /Type /Catalog /Pages 2 0 R >>"},
        {2, "<< /Type /Pages /Kids [#{kids}] /Count #{page_count} >>"},
        {font_id, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
      ]
      |> Kernel.++(page_objects)
      |> Enum.sort_by(&elem(&1, 0))

    header = "%PDF-1.4\n"

    {body, offsets, _position} =
      Enum.reduce(objects, {"", %{}, byte_size(header)}, fn {id, value},
                                                            {body, offsets, position} ->
        object = "#{id} 0 obj\n#{value}\nendobj\n"
        {body <> object, Map.put(offsets, id, position), position + byte_size(object)}
      end)

    max_id = objects |> Enum.map(&elem(&1, 0)) |> Enum.max()
    xref_position = byte_size(header) + byte_size(body)

    xref =
      "xref\n0 #{max_id + 1}\n0000000000 65535 f \n" <>
        Enum.map_join(1..max_id, "", fn id ->
          offset = Map.get(offsets, id, 0)
          flag = if Map.has_key?(offsets, id), do: "n", else: "f"
          String.pad_leading(to_string(offset), 10, "0") <> " 00000 #{flag} \n"
        end)

    header <>
      body <>
      xref <>
      "trailer\n<< /Size #{max_id + 1} /Root 1 0 R >>\nstartxref\n#{xref_position}\n%%EOF\n"
  end
end
