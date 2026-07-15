defmodule Dramatizer.Assets.Store do
  @moduledoc "Filesystem operations constrained to the configured AssetStore root."

  def root do
    :dramatizer
    |> Application.fetch_env!(:asset_store_root)
    |> Path.expand()
  end

  def staging_relative(intent_id), do: Path.join("staging", "#{intent_id}.part")

  def final_relative(sha256) do
    Path.join(["final", String.slice(sha256, 0, 2), String.slice(sha256, 2, 2), sha256])
  end

  def absolute(relative_path) do
    expanded = Path.expand(relative_path, root())
    relative = expanded |> Path.relative_to(root()) |> String.replace("\\", "/")

    if relative == "." or
         (Path.type(relative) == :relative and relative != ".." and
            not String.starts_with?(relative, "../")) do
      expanded
    else
      raise ArgumentError, "asset path escapes configured root"
    end
  end

  def write_staging(relative_path, bytes) when is_binary(bytes) do
    path = absolute(relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, bytes, [:binary])
  end

  def promote(staging_relative, final_relative) do
    staging = absolute(staging_relative)
    final = absolute(final_relative)
    File.mkdir_p!(Path.dirname(final))

    if File.exists?(final) do
      File.rm(staging)
      :ok
    else
      File.rename(staging, final)
    end
  end
end
