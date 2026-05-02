import Config

# Runtime configuration for code_puppy_control
# See CodePuppyControl.Config for centralized configuration management.
#
# Environment Variables:
# PUP_SECRET_KEY_BASE - Phoenix endpoint secret (required in prod, auto-generated for Burrito)
# PUP_DATABASE_PATH - SQLite database path (required in prod, auto-defaulted for Burrito)
# PUP_PYTHON_WORKER_SCRIPT - Python worker entry point (required in prod)
# PUP_HISTORY_LIMIT - Event history size limit (default: 1000)
# PUP_WEBSOCKET_SECRET - WebSocket auth secret (optional)
#
# Legacy names (deprecated but supported):
# SECRET_KEY_BASE -> PUP_SECRET_KEY_BASE
# DATABASE_PATH -> PUP_DATABASE_PATH
# PYTHON_WORKER_SCRIPT -> PUP_PYTHON_WORKER_SCRIPT
#
# Burrito single-binary fallback:
# When running as a Burrito binary (__BURRITO env var is set), PUP_SECRET_KEY_BASE
# and PUP_DATABASE_PATH are auto-generated/persisted under the system user-data
# directory (:filename.basedir(:user_data, "code_puppy")). This avoids requiring
# env vars for self-contained distribution while respecting ADR-003 isolation
# (NOT writing to ~/.code_puppy/).

# Store the config environment atom for runtime detection
config :code_puppy_control, :env, config_env()

if config_env() == :prod do
  # Fast-path --help / --version past validation and config loading.
  # Required for Burrito-packaged binaries to display help without requiring
  # PUP_PYTHON_WORKER_SCRIPT, PUP_SECRET_KEY_BASE, etc.
  help_mode =
    CodePuppyControl.Config.cli_help_or_version_flag?(:init.get_plain_arguments())

  unless help_mode do
    # Validate and load required configuration
    # CodePuppyControl.Config handles validation and legacy name support
    :ok = CodePuppyControl.Config.validate!()

    # Load configuration values via centralized module
    # This provides typed accessors, validation, and deprecation warnings
    secret_key_base = CodePuppyControl.Config.secret_key_base()
    database_path = CodePuppyControl.Config.database_path()
    python_worker_script = CodePuppyControl.Config.python_worker_script()
    history_limit = CodePuppyControl.Config.history_limit()
    websocket_secret = CodePuppyControl.Config.websocket_secret()

    # Apply to respective modules
    config :code_puppy_control, CodePuppyControlWeb.Endpoint, secret_key_base: secret_key_base
    config :code_puppy_control, CodePuppyControl.Repo, database: database_path
    config :code_puppy_control, :python_worker_script, python_worker_script
    config :code_puppy_control, :history_limit, history_limit

    if websocket_secret do
      config :code_puppy_control, :websocket_secret, websocket_secret
    end
  end

  # In help_mode, intentionally leave config unpopulated.
  # application.ex:start/2 detects help mode and starts an empty
  # supervision tree, so no child needs these values.
else
  # Development and test environments
  # Use relaxed validation - defaults are acceptable

  # Python worker script with legacy fallback
  python_script =
    System.get_env("PUP_PYTHON_WORKER_SCRIPT") ||
      System.get_env("PYTHON_WORKER_SCRIPT") ||
      "/tmp/mock_python_worker.py"

  # Log deprecation warning if legacy name is used
  if System.get_env("PYTHON_WORKER_SCRIPT") && !System.get_env("PUP_PYTHON_WORKER_SCRIPT") do
    require Logger
    Logger.warning("PYTHON_WORKER_SCRIPT is deprecated. Please use PUP_PYTHON_WORKER_SCRIPT.")
  end

  config :code_puppy_control, :python_worker_script, python_script

  # History limit (can be overridden in dev/test)
  history_limit_env = System.get_env("PUP_HISTORY_LIMIT", "1000")

  history_limit =
    case history_limit_env do
      "" -> 1000
      value -> String.to_integer(value)
    end

  config :code_puppy_control, :history_limit, history_limit
end
