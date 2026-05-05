import Config

# NOTE: These {:system, ...} references use the legacy env var names
# (SECRET_KEY_BASE, DATABASE_PATH). In production, runtime.exs overrides
# both via CodePuppyControl.Config, which resolves PUP_-prefixed names
# first and falls back to legacy names with a deprecation warning.
# The values here serve as a compile-time fallback only.

config :code_puppy_control, CodePuppyControlWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  secret_key_base: {:system, "SECRET_KEY_BASE"},
  server: true

config :logger, level: :info

config :code_puppy_control, CodePuppyControl.Repo,
  database: {:system, "DATABASE_PATH"},
  pool_size: 10
