# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hermitscale, :scopes,
  organization: [
    default: true,
    module: Hermitscale.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:organization, :id],
    schema_key: :org_id,
    schema_type: :string,
    test_data_fixture: Hermitscale.AccountsFixtures,
    test_setup_helper: :log_in_workos_user
  ]

config :hermitscale,
  ecto_repos: [Hermitscale.Repo],
  generators: [timestamp_type: :utc_datetime]

config :hermitscale, Oban,
  engine: Oban.Engines.Basic,
  repo: Hermitscale.Repo,
  queues: [default: 10, triggers: 10],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

config :hermitscale, Hermitscale.Triggers,
  start_runtime?: true,
  webhook_await_timeout_ms: 30_000

config :hermitscale, Hermitscale.Auth, provider: Hermitscale.Auth.WorkOS

config :hermitscale, Hermitscale.WorkOS.Client,
  base_url: "https://api.workos.com",
  receive_timeout: 10_000,
  max_retries: 2

config :hermitscale, Hermitscale.WorkOS.JWT, jwks_cache_ttl_seconds: 300

# Configure the endpoint
config :hermitscale, HermitscaleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HermitscaleWeb.ErrorHTML, json: HermitscaleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hermitscale.PubSub,
  live_view: [signing_salt: "HQUwIGrq"]

# Serves published apps on a separate listener; see HermitscaleWeb.AppsEndpoint.
config :hermitscale, HermitscaleWeb.AppsEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: HermitscaleWeb.ErrorHTML], layout: false]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :hermitscale, Hermitscale.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hermitscale: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  hermitscale: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "code",
  "state",
  "access_token",
  "refresh_token",
  "workos_session"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
