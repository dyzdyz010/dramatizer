import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dramatizer, Dramatizer.Repo,
  url:
    System.get_env(
      "TEST_DATABASE_URL",
      "ecto://postgres:postgres@127.0.0.1:55432/dramatizer_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: min(System.schedulers_online(), 10)

config :dramatizer, Oban, testing: :manual, queues: false, plugins: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dramatizer, DramatizerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dfZPWIyxG7hm1baskS9xg7frjwYMu6ywK91uRbqOaDqf9aZMXNLOxcqu5spJ0ZUa",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
