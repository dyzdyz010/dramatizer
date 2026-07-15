defmodule Mix.Tasks.Dramatizer.Assets.Verify do
  use Mix.Task

  @shortdoc "Verify every AssetVersion blob and report unreferenced final blobs"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    report = Dramatizer.Backup.verify_assets()
    Mix.shell().info(Jason.encode!(report, pretty: true))

    if report["status"] != "ok" do
      Mix.raise("AssetStore verification failed")
    end
  end
end
