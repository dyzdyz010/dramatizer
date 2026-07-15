defmodule Dramatizer.Backup do
  @moduledoc "Backup manifests, AssetStore consistency scans, and restore verification."

  import Ecto.Query

  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Assets.Store
  alias Dramatizer.Repo

  @schema_version 1
  @secret_key_pattern ~r/(api.?key|authorization|password|secret|token)/i

  def manifest do
    %{
      "schema_version" => @schema_version,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "assets" => asset_entries(),
      "config" => effective_config()
    }
  end

  def verify_assets do
    entries = asset_entries()
    paths = MapSet.new(entries, &normalize_relative(&1["relative_path"]))

    {missing, corrupt} =
      Enum.reduce(entries, {[], []}, fn entry, {missing, corrupt} ->
        path = Store.absolute(entry["relative_path"])

        cond do
          not File.regular?(path) ->
            {[entry | missing], corrupt}

          not valid_file?(path, entry) ->
            {missing, [entry | corrupt]}

          true ->
            {missing, corrupt}
        end
      end)

    orphan =
      final_files(Store.root())
      |> Enum.map(&relative_to_root(&1, Store.root()))
      |> Enum.reject(&MapSet.member?(paths, &1))
      |> Enum.sort()

    report(entries, missing, corrupt, orphan)
  end

  def verify_manifest(%{"schema_version" => @schema_version, "assets" => entries})
      when is_list(entries) do
    expected = MapSet.new(entries, &normalize_relative(&1["relative_path"]))

    {missing, corrupt} =
      Enum.reduce(entries, {[], []}, fn entry, {missing, corrupt} ->
        path = Store.absolute(entry["relative_path"])

        cond do
          not File.regular?(path) -> {[entry | missing], corrupt}
          not valid_file?(path, entry) -> {missing, [entry | corrupt]}
          true -> {missing, corrupt}
        end
      end)

    orphan =
      final_files(Store.root())
      |> Enum.map(&relative_to_root(&1, Store.root()))
      |> Enum.reject(&MapSet.member?(expected, &1))
      |> Enum.sort()

    report(entries, missing, corrupt, orphan)
  end

  def verify_manifest(_manifest) do
    %{
      "status" => "error",
      "asset_count" => 0,
      "missing" => [],
      "corrupt" => [],
      "orphan" => [],
      "manifest_error" => "unsupported_schema"
    }
  end

  def copy_asset_store(source_root, target_root) do
    source = Path.expand(source_root)
    target = Path.expand(target_root)

    if source == target do
      {:error, :source_and_target_must_differ}
    else
      File.mkdir_p!(target)
      copy_tree(Path.join(source, "final"), Path.join(target, "final"))
    end
  end

  defp asset_entries do
    Repo.all(from asset in AssetVersion, order_by: [asc: asset.id])
    |> Enum.map(fn asset ->
      %{
        "id" => asset.id,
        "project_id" => asset.project_id,
        "blob_hash" => asset.blob_hash,
        "relative_path" => normalize_relative(asset.relative_path),
        "byte_size" => asset.byte_size,
        "mime_type" => asset.mime_type
      }
    end)
  end

  defp effective_config do
    %{
      "provider_mode" => Application.fetch_env!(:dramatizer, :provider_mode),
      "model_defaults" => Application.fetch_env!(:dramatizer, :model_defaults),
      "ffmpeg" => Path.basename(Application.fetch_env!(:dramatizer, :ffmpeg_path)),
      "ffprobe" => Path.basename(Application.fetch_env!(:dramatizer, :ffprobe_path))
    }
    |> stringify()
    |> sanitize()
  end

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if Regex.match?(@secret_key_pattern, key) and key != "credential_ref" do
        {key, "[REDACTED]"}
      else
        {key, sanitize(nested)}
      end
    end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value), do: value

  defp report(entries, missing, corrupt, orphan) do
    issues? = missing != [] or corrupt != [] or orphan != []

    %{
      "status" => if(issues?, do: "error", else: "ok"),
      "asset_count" => length(entries),
      "missing" => Enum.reverse(missing),
      "corrupt" => Enum.reverse(corrupt),
      "orphan" => orphan
    }
  end

  defp valid_file?(path, entry) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size == entry["byte_size"],
         {:ok, bytes} <- File.read(path) do
      sha256(bytes) == entry["blob_hash"]
    else
      _ -> false
    end
  end

  defp final_files(root) do
    root
    |> Path.join("final/**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp relative_to_root(path, root) do
    path |> Path.relative_to(root) |> normalize_relative()
  end

  defp normalize_relative(path), do: String.replace(path, "\\", "/")

  defp copy_tree(source, target) do
    if File.dir?(source) do
      File.rm_rf!(target)

      case File.cp_r(source, target) do
        {:ok, _paths} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    else
      File.mkdir_p!(target)
      :ok
    end
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
