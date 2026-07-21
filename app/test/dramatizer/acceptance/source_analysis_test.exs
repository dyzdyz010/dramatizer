defmodule Dramatizer.Acceptance.SourceAnalysisTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.DAG
  alias Dramatizer.Generation.Attempt
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Sources
  alias Dramatizer.Sources.Parser
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-at-source-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "AT-003 TXT Markdown 文本 PDF 保留定位且 required 失败不重跑成功兄弟" do
    txt = fixture("novel.txt")
    markdown = fixture("novel.md")
    pdf = temporary("novel.pdf", text_pdf("PDF text layer"))

    assert {:ok, %{format: :text, locators: [_ | _]}} = Parser.parse(txt)
    assert {:ok, %{format: :markdown, locators: [_ | _]}} = Parser.parse(markdown)

    assert {:ok, %{format: :pdf, text: "PDF text layer", locators: [%{"page" => 1}]}} =
             Parser.parse(pdf)

    assert {:ok, project} = Projects.create_project(%{name: "AT-003 来源与 DAG"})
    assert {:ok, _document, source} = Sources.import(project, txt)
    assert {:ok, run, nodes} = DAG.start(project, [source.id])
    by_key = Map.new(nodes, &{&1.node_key, &1})

    assert {:ok, people_running} = Workflow.transition_node(by_key["people_relations"], :running)

    assert {:ok, people_done} =
             Workflow.transition_node(people_running, :succeeded, %{result: %{"items" => []}})

    assert people_done.status == :succeeded

    assert {:ok, events_running} = Workflow.transition_node(by_key["events_timeline"], :running)

    assert {:ok, failed} =
             Workflow.transition_node(events_running, :failed, %{error_code: "injected"})

    assert Workflow.queue_ready_nodes(run.id) == []
    assert Repo.get!(NodeRun, people_done.id).status == :succeeded
    assert {:ok, retried} = Workflow.retry_node(failed)
    assert retried.run_count == 2
    assert Repo.get!(NodeRun, people_done.id).run_count == 1
  end

  test "AT-004 非法 JSON、缺定位与悬空引用最多两次修复并给出稳定路径" do
    assert {:ok, project} = Projects.create_project(%{name: "AT-004 结构修复"})
    assert {:ok, _document, source} = Sources.import(project, fixture("novel.txt"))
    assert {:ok, _run, nodes} = DAG.start(project, [source.id])
    node = Enum.find(nodes, &(&1.node_key == "people_relations"))

    missing_locator = %{
      "items" => [item("person:p1", [], [])]
    }

    dangling = %{
      "items" => [item("person:p1", ["person:missing"], [locator(source.id)])]
    }

    valid = %{"items" => [item("person:p1", [], [locator(source.id)])]}
    assert {:ok, succeeded} = Analysis.run_node(node, project, ["{bad", missing_locator, valid])
    assert succeeded.result["repair_attempts"] == 2
    assert Repo.aggregate(Attempt, :count) == 3

    errors =
      succeeded.result["provider_request_snapshot_ids"]
      |> Enum.map(fn snapshot_id ->
        Repo.get_by!(Attempt,
          provider_request_snapshot_id: snapshot_id,
          attempt_number: 1
        )
      end)
      |> Enum.map(&get_in(&1.response_metadata, ["validation_errors"]))

    assert get_in(Enum.at(errors, 0), [Access.at(0), "path"]) == "/"
    assert get_in(Enum.at(errors, 1), [Access.at(0), "path"]) == "/items/0/locators"

    assert {:error, validation} =
             Dramatizer.Analysis.Validator.validate(:people_relations, dangling,
               source_revision_ids: [source.id]
             )

    assert %{code: :dangling_reference, path: "/items/0/references/0"} in validation
  end

  defp item(id, references, locators) do
    %{
      "id" => id,
      "kind" => "person",
      "name" => "林夏",
      "source_semantics" => "source_grounded",
      "locators" => locators,
      "references" => references,
      "data" => %{}
    }
  end

  defp locator(source_id),
    do: %{"source_revision_id" => source_id, "start_offset" => 0, "end_offset" => 2}

  defp fixture(name), do: Path.expand("../../support/fixtures/sources/#{name}", __DIR__)

  defp temporary(name, bytes) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp text_pdf(text) do
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"

    objects = [
      {1, "<< /Type /Catalog /Pages 2 0 R >>"},
      {2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"},
      {3,
       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"},
      {4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"},
      {5, "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"}
    ]

    header = "%PDF-1.4\n"

    {body, offsets, _position} =
      Enum.reduce(objects, {"", %{}, byte_size(header)}, fn {id, value},
                                                            {body, offsets, position} ->
        object = "#{id} 0 obj\n#{value}\nendobj\n"
        {body <> object, Map.put(offsets, id, position), position + byte_size(object)}
      end)

    xref_position = byte_size(header) + byte_size(body)

    xref =
      "xref\n0 6\n0000000000 65535 f \n" <>
        Enum.map_join(1..5, "", fn id ->
          String.pad_leading(to_string(offsets[id]), 10, "0") <> " 00000 n \n"
        end)

    header <>
      body <> xref <> "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_position}\n%%EOF\n"
  end
end
