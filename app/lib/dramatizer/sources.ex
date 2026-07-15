defmodule Dramatizer.Sources do
  @moduledoc "Immutable whole-document source import and exact revision replay."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Sources.{Parser, SourceDocument, SourceRevision}

  def import(project, path, role \\ :volume)

  def import(%Project{} = project, path, role) when role in [:volume, :companion] do
    with {:ok, parsed} <- Parser.parse(path),
         {:ok, document} <-
           %SourceDocument{}
           |> SourceDocument.create_changeset(%{
             project_id: project.id,
             role: role,
             name: Path.basename(path)
           })
           |> Repo.insert(),
         {:ok, revision} <- persist_revision(project, document, path, parsed) do
      {:ok, document, revision}
    end
  end

  def replace(%SourceDocument{} = document, path) do
    project = Repo.get!(Project, document.project_id)

    with {:ok, parsed} <- Parser.parse(path) do
      persist_revision(project, document, path, parsed)
    end
  end

  def analysis_input(%Project{} = project, revision_ids) when is_list(revision_ids) do
    revisions = Enum.map(revision_ids, &Repo.get(SourceRevision, &1))

    cond do
      Enum.any?(revisions, &is_nil/1) ->
        {:error, :source_revision_not_found}

      Enum.any?(revisions, &(&1.project_id != project.id)) ->
        {:error, :source_revision_project_mismatch}

      true ->
        with {:ok, texts} <- read_revision_texts(revisions) do
          text = combine_sources(texts)

          {:ok,
           %{
             strategy: :whole_document,
             text: text,
             sources: revisions,
             content_hash: CanonicalJSON.hash(%{"revision_ids" => revision_ids, "text" => text}),
             truncated: false,
             chunked: false
           }}
        end
    end
  end

  defp persist_revision(project, document, path, parsed) do
    previous =
      Repo.one(
        from revision in SourceRevision,
          where: revision.source_document_id == ^document.id,
          order_by: [desc: revision.revision],
          limit: 1
      )

    revision_number = if previous, do: previous.revision + 1, else: 1
    content_hash = sha256(parsed.text)

    with {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: "source_text",
             expected_mime: "text/plain; charset=utf-8",
             idempotency_key: "source:#{document.id}:#{revision_number}:#{content_hash}"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, parsed.text),
         {:ok, asset} <-
           Assets.finalize(staged, %{
             "origin" => "source_import",
             "source_document_id" => document.id,
             "source_revision" => revision_number,
             "original_filename" => Path.basename(path),
             "source_format" => Atom.to_string(parsed.format),
             "parser_version" => parsed.parser_version
           }) do
      %SourceRevision{}
      |> SourceRevision.create_changeset(%{
        source_document_id: document.id,
        project_id: project.id,
        revision: revision_number,
        parent_revision_id: previous && previous.id,
        asset_version_id: asset.id,
        source_format: parsed.format,
        original_filename: Path.basename(path),
        parser_version: parsed.parser_version,
        content_hash: content_hash,
        character_count: String.length(parsed.text),
        byte_count: byte_size(parsed.text),
        locators: %{"entries" => parsed.locators},
        metadata: %{"whole_document" => true, "chunked" => false, "truncated" => false}
      })
      |> Repo.insert()
    end
  end

  defp read_revision_texts(revisions) do
    Enum.reduce_while(revisions, {:ok, []}, fn revision, {:ok, acc} ->
      asset = Assets.get_asset!(revision.asset_version_id)

      case File.read(Assets.absolute_path(asset)) do
        {:ok, text} -> {:cont, {:ok, acc ++ [{revision, text}]}}
        {:error, reason} -> {:halt, {:error, {:source_blob_unavailable, revision.id, reason}}}
      end
    end)
  end

  defp combine_sources([{_revision, text}]), do: text

  defp combine_sources(revision_texts) do
    Enum.map_join(revision_texts, "\n", fn {revision, text} ->
      "<source revision_id=\"#{revision.id}\" role_revision=\"#{revision.revision}\">\n#{text}\n</source>"
    end)
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
