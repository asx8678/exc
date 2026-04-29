import Config

# Allow PUP_TEST_SESSION_ROOT to be honoured in validate_storage_dir!/1
# during tests only.  Production builds do not set this flag, so the env var
# is silently ignored outside test — prevents expanding allowed roots via
# env var in prod.  (code_puppy-dku)
config :code_puppy_control, :allow_test_session_root, true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :code_puppy_control, CodePuppyControlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_that_is_at_least_64_bytes_long_123456789012345678901234567890",
  pubsub_server: CodePuppyControl.PubSub,
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Python worker script for testing (mock path)
config :code_puppy_control, :python_worker_script, "/tmp/mock_python_worker.py"

# WebSocket auth secret for testing
config :code_puppy_control, :websocket_secret, "test_websocket_secret_for_testing"

# Ensure Oban config exists for tests
# Use :inline mode for testing and disable PostgreSQL-specific features
config :code_puppy_control, Oban,
  engine: Oban.Engines.Basic,
  peer: false,
  queues: false,
  repo: CodePuppyControl.Repo,
  notifier: Oban.Notifiers.Isolated,
  testing: :inline

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# ---------------------------------------------------------------------------
# Test database (SQLite)
# ---------------------------------------------------------------------------
#
# Why NOT PostgreSQL?
#   - The repo, migrations, and Oban config are all SQLite-specific.
#   - Switching to Postgres would require separate migration sets, a running
#     Postgres instance in CI and locally, and Oban engine changes.
#   - For a test suite that runs in <60s on a laptop, SQLite is the right
#     trade-off: zero infra, instant startup, and parity with production.
#
# The test DB lives in System.tmp_dir!() so:
#   - Keeps the repo clean (no priv/repo/test.db in the working tree)
#   - OS cleans it up automatically on reboot
#   - Partition-aware via MIX_TEST_PARTITION so parallel/partitioned runs
#     do not collide — different partitions get unique filenames
#
# Note: This does NOT provide an automatically fresh DB between runs. If you
# need unique DBs across partitioned runs, you must override PUP_TEST_DB with
# a unique path per partition yourself.
#
# Override the path entirely with PUP_TEST_DB if needed.
# ---------------------------------------------------------------------------

test_db_path =
  System.get_env("PUP_TEST_DB") ||
    Path.join([
      System.tmp_dir!(),
      "code_puppy_control_test_p#{System.get_env("MIX_TEST_PARTITION", "1")}.db"
    ])

config :code_puppy_control, CodePuppyControl.Repo,
  database: test_db_path,
  pool_size: 2,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite pragmas tuned for test speed (safe for single-connection sandbox)
  journal_mode: :wal,
  temp_store: :memory,
  cache_size: -64_000,
  busy_timeout: 5_000,
  # :off is safe here because this is temporary test data under tmp; durability
  # is not important, and skipping fsync gives a noticeable speedup on macOS APFS.
  synchronous: :off
