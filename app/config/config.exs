# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

provider_mode =
  case System.get_env("DRAMATIZER_PROVIDER", "fake") do
    "openai" -> :openai
    _ -> :fake
  end

local_python =
  case :os.type() do
    {:win32, _} -> Path.expand("../.venv/Scripts/python.exe", __DIR__)
    _ -> Path.expand("../.venv/bin/python", __DIR__)
  end

config :dramatizer,
  ecto_repos: [Dramatizer.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  asset_store_root:
    System.get_env("DRAMATIZER_ASSET_STORE_ROOT", Path.expand("../../var/assets", __DIR__)),
  media_worker_python: System.get_env("DRAMATIZER_PYTHON", local_python),
  ffmpeg_path: System.get_env("DRAMATIZER_FFMPEG", "ffmpeg"),
  ffprobe_path: System.get_env("DRAMATIZER_FFPROBE", "ffprobe"),
  provider_mode: provider_mode

config :dramatizer, Oban,
  repo: Dramatizer.Repo,
  queues: [workflow: 5, generation: 3, media: 2, qc: 3],
  plugins: [{Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}]

text_model = %{
  adapter: "openai_responses",
  credential_ref: "OPENAI_API_KEY",
  model: "gpt-5.6-terra",
  params: %{"reasoning" => %{"effort" => "medium"}}
}

image_model = %{
  adapter: "openai_images",
  credential_ref: "OPENAI_API_KEY",
  model: "gpt-image-2",
  params: %{"quality" => "medium", "size" => "1024x1536"}
}

config :dramatizer, :model_defaults, %{
  people_relations: text_model,
  places_props_world: text_model,
  events_timeline: text_model,
  entity_merge: text_model,
  episode_candidates: text_model,
  conflict_check: text_model,
  directing_proposal: text_model,
  image_prompt: text_model,
  structured_repair: text_model,
  semantic_qc: text_model,
  reference_image: image_model,
  shot_keyframe: image_model,
  image_edit: image_model
}

# Configure the endpoint
config :dramatizer, DramatizerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DramatizerWeb.ErrorHTML, json: DramatizerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dramatizer.PubSub,
  live_view: [signing_salt: "frf0rZEz"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dramatizer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  dramatizer: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
