defmodule Dramatizer.SourcesTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Sources
  alias Dramatizer.Sources.{SourceRevision, TokenEstimator}

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-sources-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "imports volume and companion sources and keeps replacement revisions replayable" do
    assert {:ok, project} = Projects.create_project(%{name: "整书导入"})
    novel = fixture_path("novel.txt")
    companion = fixture_path("novel.md")

    assert {:ok, volume, first_revision} = Sources.import(project, novel, :volume)

    assert {:ok, _companion_document, companion_revision} =
             Sources.import(project, companion, :companion)

    assert first_revision.revision == 1
    assert first_revision.parser_version == "source-parser-v1"

    replacement_path = temporary_source("replacement.txt", "替换后的完整正文\n不能覆盖旧版本")
    assert {:ok, second_revision} = Sources.replace(volume, replacement_path)
    assert second_revision.revision == 2
    assert second_revision.parent_revision_id == first_revision.id

    assert {:ok, old_input} =
             Sources.analysis_input(project, [first_revision.id, companion_revision.id])

    assert old_input.strategy == :whole_document
    assert String.contains?(old_input.text, "林夏站在车站")
    refute String.contains?(old_input.text, "替换后的完整正文")
    assert Enum.map(old_input.sources, & &1.id) == [first_revision.id, companion_revision.id]

    assert {:ok, current_input} = Sources.analysis_input(project, [second_revision.id])
    assert current_input.text == "替换后的完整正文\n不能覆盖旧版本"
    assert current_input.chunked == false
    assert current_input.truncated == false
  end

  test "source revisions are immutable at the database boundary" do
    assert {:ok, project} = Projects.create_project(%{name: "来源不可变"})
    assert {:ok, _document, revision} = Sources.import(project, fixture_path("novel.txt"))

    assert_raise Postgrex.Error, ~r/immutable_record/, fn ->
      Repo.update_all(from(item in SourceRevision, where: item.id == ^revision.id),
        set: [content_hash: String.duplicate("0", 64)]
      )
    end
  end

  test "whole-document preflight reports measured, reserved, and context values without truncation" do
    text = String.duplicate("中", 101)

    assert {:error, :document_too_large, details} =
             TokenEstimator.preflight(text, %{model: "tiny", context_window: 120}, 20)

    assert details.measured_tokens == 101
    assert details.reserved_tokens == 20
    assert details.context_window == 120
    assert details.estimator_version == "whole-document-v1"

    assert {:ok, accepted} =
             TokenEstimator.preflight(text, %{model: "large", context_window: 200}, 20)

    assert accepted.measured_tokens == 101
    assert accepted.total_tokens == 121
    assert accepted.strategy == :whole_document
  end

  defp fixture_path(name), do: Path.expand("../support/fixtures/sources/#{name}", __DIR__)

  defp temporary_source(name, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-source-#{System.unique_integer([:positive])}-#{name}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
