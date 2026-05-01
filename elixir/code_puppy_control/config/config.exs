import Config

config :code_puppy_control,
  ecto_repos: [CodePuppyControl.Repo],
  generators: [timestamp_type: :utc_datetime]

# Endpoint defaults — render_errors required so exceptions escaping
# LiveView mounts surface as a real 500 instead of a template-not-found.
config :code_puppy_control, CodePuppyControlWeb.Endpoint,
  render_errors: [
    formats: [html: CodePuppyControlWeb.ErrorView, json: CodePuppyControlWeb.ErrorView],
    layout: false
  ],
  pubsub_server: CodePuppyControl.PubSub,
  # LiveView signing salt — required for the admin LiveView UI
  # (code_puppy-yge.3). The actual signing key still derives from
  # secret_key_base; this salt scopes the signed payload to LiveView.
  live_view: [signing_salt: "cpc-admin-lv-7a9c2f"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Oban configuration with SQLite support
config :code_puppy_control, Oban,
  engine: Oban.Engines.Lite,
  queues: [default: 10, scheduled: 5, workflows: 5],
  repo: CodePuppyControl.Repo,
  plugins: [
    # Prune completed jobs older than 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue orphaned jobs after 30 minutes
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Distributed packs — all disabled by default.
# Enabled per-environment or via runtime config.
config :code_puppy_control, :distributed_packs,
  enabled: false,
  workers: [],
  heartbeat_interval: 15_000,
  disconnect_timeout: 30_000,
  connect_timeout: 5_000

import_config "#{config_env()}.exs"
