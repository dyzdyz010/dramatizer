defmodule Mix.Tasks.Dramatizer.Backup.Manifest do
  use Mix.Task

  @shortdoc "Write a non-secret AssetStore and effective-config backup manifest"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {options, _rest, invalid} =
      OptionParser.parse(args, strict: [output: :string], aliases: [o: :output])

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    body = Dramatizer.Backup.manifest() |> Jason.encode!(pretty: true)

    case options[:output] do
      nil ->
        Mix.shell().info(body)

      path ->
        path = Path.expand(path)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body <> "\n")
        Mix.shell().info("Backup manifest written: #{path}")
    end
  end
end
