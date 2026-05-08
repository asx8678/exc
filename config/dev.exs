import Config

config :code_puppy_control, CodePuppyControlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_that_is_at_least_64_bytes_long_for_dev_only_12345678901234567890",
  watchers: []

config :logger, :console, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :code_puppy_control, CodePuppyControl.Repo,
  database: "priv/dev.db",
  pool_size: 5

# Dev mode: no websocket secret means all connections are allowed
config :code_puppy_control, :websocket_secret, nil
