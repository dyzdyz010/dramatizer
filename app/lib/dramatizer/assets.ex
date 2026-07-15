defmodule Dramatizer.Assets do
  @moduledoc "Recoverable staging and immutable, content-addressed AssetVersions."

  alias Dramatizer.Assets.{AssetVersion, Store, UploadIntent}
  alias Dramatizer.Media.Worker
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo

  def create_upload_intent(%Project{id: project_id}, attrs) do
    intent_id = Ecto.UUID.generate()
    idempotency_key = Map.get(attrs, :idempotency_key, Ecto.UUID.generate())

    values =
      attrs
      |> Map.new()
      |> Map.put(:id, intent_id)
      |> Map.put(:project_id, project_id)
      |> Map.put(:staging_path, Store.staging_relative(intent_id))
      |> Map.put(:idempotency_key, idempotency_key)

    %UploadIntent{id: intent_id}
    |> UploadIntent.create_changeset(values)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :idempotency_key]
    )

    {:ok, Repo.get_by!(UploadIntent, project_id: project_id, idempotency_key: idempotency_key)}
  end

  def stage_bytes(%UploadIntent{id: id}, bytes) when is_binary(bytes) and byte_size(bytes) > 0 do
    intent = Repo.get!(UploadIntent, id)

    if intent.status in [:staging, :failed] do
      :ok = Store.write_staging(intent.staging_path, bytes)
      sha256 = hash(bytes)

      intent
      |> UploadIntent.stage_changeset(%{
        status: :staging,
        byte_size: byte_size(bytes),
        sha256: sha256,
        error_code: nil
      })
      |> Repo.update()
    else
      {:error, :already_finalized}
    end
  end

  def stage_bytes(%UploadIntent{}, _bytes), do: {:error, :empty_asset}

  def finalize(intent, lineage \\ %{})

  def finalize(%UploadIntent{id: id}, lineage) when is_map(lineage) do
    intent = Repo.get!(UploadIntent, id)

    case intent.status do
      :finalized ->
        {:ok, Repo.get!(AssetVersion, intent.finalized_asset_id)}

      :staging ->
        finalize_staged(intent, normalize_map(lineage))

      :failed ->
        {:error, atom_error(intent.error_code)}
    end
  end

  def import_file(%Project{} = project, path, attrs) do
    with {:ok, bytes} <- File.read(path),
         {:ok, intent} <- create_upload_intent(project, attrs),
         {:ok, staged} <- stage_bytes(intent, bytes) do
      finalize(staged, %{"origin" => "upload", "original_name" => Path.basename(path)})
    end
  end

  def absolute_path(%AssetVersion{relative_path: relative_path}),
    do: Store.absolute(relative_path)

  def verify(%AssetVersion{} = asset) do
    with {:ok, bytes} <- File.read(absolute_path(asset)),
         true <- byte_size(bytes) == asset.byte_size,
         true <- hash(bytes) == asset.blob_hash do
      :ok
    else
      {:error, :enoent} -> {:error, :missing_blob}
      false -> {:error, :hash_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_asset!(id), do: Repo.get!(AssetVersion, id)

  defp finalize_staged(intent, lineage) do
    staging_path = Store.absolute(intent.staging_path)

    with {:ok, bytes} <- File.read(staging_path),
         :ok <- verify_staged_bytes(intent, bytes),
         {:ok, probe} <- probe(intent.expected_mime, staging_path),
         final_relative = Store.final_relative(intent.sha256),
         :ok <- Store.promote(intent.staging_path, final_relative),
         {:ok, asset} <- persist_finalize(intent, lineage, probe, final_relative) do
      {:ok, asset}
    else
      {:error, code} when is_atom(code) -> mark_failed(intent, code)
      {:error, %{code: code}} -> mark_failed(intent, code)
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> mark_failed(intent, reason)
    end
  end

  defp verify_staged_bytes(intent, bytes) do
    cond do
      byte_size(bytes) != intent.byte_size -> {:error, :staged_size_mismatch}
      hash(bytes) != intent.sha256 -> {:error, :staged_hash_mismatch}
      true -> :ok
    end
  end

  defp probe("image/" <> _rest, path), do: Worker.run(:probe_image, %{"path" => path})
  defp probe(_mime, _path), do: {:ok, %{}}

  defp persist_finalize(intent, lineage, probe, final_relative) do
    parent_asset_id = lineage["parent_asset_id"]
    source = lineage["origin"] || if(parent_asset_id, do: "edited", else: "upload")

    Repo.transaction(fn ->
      locked = Repo.get!(UploadIntent, intent.id, lock: "FOR UPDATE")

      if locked.status == :finalized do
        Repo.get!(AssetVersion, locked.finalized_asset_id)
      else
        asset =
          %AssetVersion{}
          |> AssetVersion.create_changeset(%{
            project_id: intent.project_id,
            upload_intent_id: intent.id,
            kind: intent.purpose,
            source: source,
            parent_asset_id: parent_asset_id,
            blob_hash: intent.sha256,
            relative_path: final_relative,
            mime_type: resolved_mime(intent.expected_mime, probe),
            byte_size: intent.byte_size,
            width: probe["width"],
            height: probe["height"],
            metadata: probe,
            lineage: lineage
          })
          |> Repo.insert!()

        locked
        |> UploadIntent.finalize_changeset(asset.id)
        |> Repo.update!()

        asset
      end
    end)
    |> case do
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolved_mime(nil, _probe), do: "application/octet-stream"
  defp resolved_mime(expected_mime, _probe), do: expected_mime

  defp mark_failed(intent, code) do
    intent
    |> UploadIntent.fail_changeset(code)
    |> Repo.update()

    {:error, atom_error(code)}
  end

  defp normalize_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp atom_error(value) when is_atom(value), do: value

  defp atom_error(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :asset_finalize_failed
  end

  defp hash(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end
end
