import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hermitscale, Hermitscale.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hermitscale_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :hermitscale, Oban, testing: :manual

config :hermitscale, Hermitscale.Apps, domain: "apps.test"

config :hermitscale, Hermitscale.WorkOS.Client,
  api_key: "sk_test_hermitscale",
  client_id: "client_test_hermitscale",
  redirect_uri: "http://www.example.com/auth/workos/callback"

config :hermitscale, Hermitscale.WorkOS.JWT, client_id: "client_test_hermitscale"

config :hermitscale, Hermitscale.WorkOS.Session, jwt_verifier: Hermitscale.WorkOSTest.JWTVerifier

# The reconciler and scheduler are started per-test inside the SQL sandbox
# instead of globally, and webhook wait-mode falls back fast.
config :hermitscale, Hermitscale.Triggers,
  start_runtime?: false,
  webhook_await_timeout_ms: 250,
  run_opts: [executor: :inline]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hermitscale, HermitscaleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "nCDNbte9HSuM9rCn8CoJTa/zm9aBfo0ZKwdsqkxdTwvbNp5ETadJ1p0vBwYI5vfW",
  server: false

# In test we don't send emails
config :hermitscale, Hermitscale.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
