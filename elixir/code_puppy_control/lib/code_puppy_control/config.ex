defmodule CodePuppyControl.Config do
  @moduledoc """
  Top-level facade for Code Puppy configuration.

  Delegates to focused sub-modules under `CodePuppyControl.Config.*`:

  | Module | Responsibility |
  |--------|---------------|
  | `Config.Loader` | INI parser, persistent_term cache, env overrides |
  | `Config.Writer` | Atomic writes (temp-file swap) |
  | `Config.Paths` | XDG paths, file/dir constants |
  | `Config.Models` | Model name, per-model settings, OpenAI params |
  | `Config.Agents` | Default agent, agent dirs, personalization |
  | `Config.TUI` | Banner colors, diff colors, display flags |
  | `Config.Cache` | Session cache, WS history, frontend emitter |
  | `Config.Limits` | Compaction, token budgets, timeouts |
  | `Config.Debug` | Feature toggles, safety levels, API keys |
  | `Config.Migrator` | Schema version migrations for puppy.cfg |

  ## Environment Variables

  All new env vars use the `PUP_` prefix. Legacy `PUPPY_*` vars are
  supported with deprecation warnings.

  | Variable | Legacy Name | Description |
  |----------|-------------|-------------|
  | `PUP_HOME` | `PUPPY_HOME` | Override all code_puppy directories |
  | `PUP_SECRET_KEY_BASE` | `SECRET_KEY_BASE` | Phoenix endpoint secret |
  | `PUP_DATABASE_PATH` | `DATABASE_PATH` | SQLite database path |
  | `PUP_MODEL` | `PUPPY_DEFAULT_MODEL` | Override model selection |
  | `PUP_AGENT` | `PUPPY_DEFAULT_AGENT` | Override default agent |
  | `PUP_DEBUG` | - | Enable debug mode |

  ## Usage

      # Direct access via sub-modules (preferred for new code)
      CodePuppyControl.Config.Models.global_model_name()
      CodePuppyControl.Config.Debug.yolo_mode?()

      # Facade access (backward-compatible)
      CodePuppyControl.Config.get_value("model")
  """

  require Logger

  alias CodePuppyControl.Config.{
    Loader,
    Writer,
    Paths,
    Models,
    Agents,
    TUI,
    Limits,
    Debug,
    Migrator
  }

  @typedoc "Application environment atom"
  @type env :: :dev | :test | :prod

  # ── Environment detection ───────────────────────────────────────────────

  @spec config_env() :: env()
  def config_env do
    Application.get_env(:code_puppy_control, :env) ||
      if Mix.env() == :test, do: :test, else: Mix.env()
  catch
    _, _ ->
      case System.get_env("MIX_ENV", "prod") do
        "dev" -> :dev
        "test" -> :test
        _ -> :prod
      end
  end

  @spec prod?() :: boolean()
  def prod?, do: config_env() == :prod

  # ── Facade: core config access ──────────────────────────────────────────

  @doc "Get a value from the default section. Delegates to `Loader.get_value/1`."
  @spec get_value(String.t()) :: String.t() | nil
  def get_value(key), do: Loader.get_value(key)

  @doc "Set a value in the default section. Delegates to `Writer.set_value/2`."
  @spec set_value(String.t(), String.t()) :: :ok
  def set_value(key, value), do: Writer.set_value(key, value)

  @doc "Get all config keys. Delegates to `Loader.keys/0`."
  @spec get_config_keys() :: [String.t()]
  def get_config_keys, do: Loader.keys()

  # ── Facade: environment-specific config ─────────────────────────────────

  @doc """
  Return the secret key base for Phoenix endpoint.

  In production, checks `PUP_SECRET_KEY_BASE` env var first, then falls back
  to `default_secret_key_base/0` if running under Burrito. Raises if neither
  is available and not running as a Burrito binary.
  Must be at least 64 bytes.
  """
  @spec secret_key_base() :: String.t()
  def secret_key_base do
    case get_string_with_legacy("PUP_SECRET_KEY_BASE", "SECRET_KEY_BASE", nil) do
      value when is_binary(value) and byte_size(value) >= 64 ->
        Application.put_env(:code_puppy_control, :secret_key_base, value)
        value

      value when is_binary(value) and byte_size(value) > 0 ->
        # Non-empty but too short — always an error, regardless of Burrito mode
        raise """
        PUP_SECRET_KEY_BASE is set but shorter than 64 bytes (got #{byte_size(value)}).
        Phoenix requires at least 64 bytes for secret_key_base.
        """

      _ ->
        # nil or empty string — fall through to Burrito/escript default or error
        cond do
          burrito_binary?() ->
            default_secret_key_base()

          escript_mode?() ->
            # In escript mode, Repo/Oban/Endpoint are skipped, so a
            # secret key is not needed for DB-dependent subsystems.
            # Generate a transient key so any code that reads this value
            # gets a valid 64-byte string, but do NOT persist it.
            default_secret_key_base()

          true ->
            raise """
            Required environment variable PUP_SECRET_KEY_BASE is missing.

            You can set it via:
              export PUP_SECRET_KEY_BASE="your-value"

            Note: The legacy name SECRET_KEY_BASE is also supported but deprecated.

            Alternatively, run as a Burrito binary or escript which auto-generates a key.
            """
        end
    end
  end

  @doc """
  Auto-generated secret key base for Burrito single-binary releases.

  On first run, generates 48 random bytes via `:crypto.strong_rand_bytes/1`
  and Base64-encodes them to a 64-byte string, then persists it to
  `<user_data>/secret_key_base` so the same key is used across restarts.

  Uses `:filename.basedir(:user_data, "code_puppy")` — NOT `~/.code_puppy/`.
  """
  @spec default_secret_key_base() :: String.t()
  def default_secret_key_base do
    user_data = user_data_dir()
    File.mkdir_p!(user_data)
    key_file = Path.join(user_data, "secret_key_base")

    case File.read(key_file) do
      {:ok, key} when byte_size(key) >= 64 ->
        key

      _ ->
        key = :crypto.strong_rand_bytes(48) |> Base.encode64()
        File.write!(key_file, key)
        key
    end
  end

  @doc """
  Returns `true` if running inside a Burrito-wrapped binary.

  Burrito sets the `__BURRITO` environment variable at launch.
  """
  @spec burrito_binary?() :: boolean()
  def burrito_binary? do
    System.get_env("__BURRITO") != nil
  end

  @doc """
  Returns `true` when running as an escript (`./pup`).

  Escript mode is detected the same way as
  `CodePuppyControl.Application.escript_mode?/0`: when the BEAM VM boots
  from an escript, `:code.priv_dir(:code_puppy_control)` returns
  `{:error, :bad_name}` because the application's `.app` file is not on
  the code path in the standard way. We also verify the returned path
  actually exists on disk.

  In escript mode, NIF libraries (like exqlite's sqlite3_nif.so) cannot be
  loaded from the zip archive, and the supervision tree degrades gracefully
  by skipping DB-dependent children (Repo, Oban, Endpoint). Therefore,
  `PUP_SECRET_KEY_BASE` and `PUP_DATABASE_PATH` are not required.

  This function is safe to call from `config/runtime.exs` — it does not
  depend on the OTP application being started.
  """
  @spec escript_mode?() :: boolean()
  def escript_mode? do
    case :code.priv_dir(:code_puppy_control) do
      {:error, _} ->
        true

      priv_dir when is_list(priv_dir) ->
        # Even if :code.priv_dir returns a path, in escript mode the
        # path points inside the zip archive and is not a real directory.
        not File.dir?(priv_dir)
    end
  end

  @doc """
  Return the database path for SQLite.

  In production, checks `PUP_DATABASE_PATH` env var first, then falls back
  to `default_database_path/0` if running under Burrito (detected via
  `__BURRITO` env var). Raises if neither is available.
  Defaults to `priv/dev.db` in dev/test.
  """
  @spec database_path() :: String.t()
  def database_path do
    if prod?() do
      case get_string_with_legacy("PUP_DATABASE_PATH", "DATABASE_PATH", nil) do
        value when is_binary(value) and byte_size(value) > 0 ->
          Application.put_env(:code_puppy_control, :database_path, value)
          value

        _ ->
          # nil or empty string — fall through to Burrito/escript default or error
          cond do
            burrito_binary?() ->
              default_database_path()

            escript_mode?() ->
              # In escript mode, Repo/Oban are skipped (exqlite NIF cannot
              # load from the zip archive), so a database path is not
              # needed. Generate a transient path so any code that reads
              # this value gets a valid string, but do NOT persist it.
              default_database_path()

            true ->
              raise """
              Required environment variable PUP_DATABASE_PATH is missing.

              You can set it via:
                export PUP_DATABASE_PATH="your-value"

              Note: The legacy name DATABASE_PATH is also supported but deprecated.

              Alternatively, run as a Burrito binary or escript which provides a sensible default.
              """
          end
      end
    else
      Application.get_env(:code_puppy_control, CodePuppyControl.Repo)[:database] ||
        get_string_with_legacy("PUP_DATABASE_PATH", "DATABASE_PATH", "priv/dev.db")
    end
  end

  @doc """
  Default database path for Burrito single-binary releases.

  Uses `:filename.basedir(:user_data, "code_puppy")` for cross-platform
  resolution (macOS: ~/Library/Application Support/code_puppy,
  Linux: ~/.local/share/code_puppy, Windows: %LOCALAPPDATA%\code_puppy).

  This path is intentionally outside `~/.code_puppy/` to respect
  ADR-003 config isolation — the Python pup owns that directory.
  """
  @spec default_database_path() :: String.t()
  def default_database_path do
    user_data = user_data_dir()
    File.mkdir_p!(user_data)
    Path.join(user_data, "data.sqlite")
  end

  @doc "Return the history limit (default `1000`)."
  @spec history_limit() :: non_neg_integer()
  def history_limit do
    Application.get_env(:code_puppy_control, :history_limit) ||
      parse_integer_env("PUP_HISTORY_LIMIT", 1000)
  end

  @doc "Return the WebSocket secret or `nil`."
  @spec websocket_secret() :: String.t() | nil
  def websocket_secret, do: System.get_env("PUP_WEBSOCKET_SECRET")

  @doc """
  Returns true if the given args list contains a --help, -h, --version,
  -v, or -V flag. Used to fast-path CLI invocations past prod config
  validation and supervision tree startup.

  Accepts charlists (as returned by `:init.get_plain_arguments/0`) or
  binaries (as in `System.argv/0`).

  ## Examples

      iex> CodePuppyControl.Config.cli_help_or_version_flag?(["--help"])
      true

      iex> CodePuppyControl.Config.cli_help_or_version_flag?([~c"--version"])
      true

      iex> CodePuppyControl.Config.cli_help_or_version_flag?(["prompt", "--model", "gpt-4"])
      false
  """
  @spec cli_help_or_version_flag?([String.t() | charlist()]) :: boolean()
  def cli_help_or_version_flag?(args) when is_list(args) do
    Enum.any?(args, fn arg ->
      str = to_string(arg)
      str in ["--help", "-h", "--version", "-v", "-V"]
    end)
  end

  def cli_help_or_version_flag?(_), do: false

  @doc """
  Validate all required config. Raises in production if missing.
  """
  @spec validate!() :: :ok
  def validate! do
    if prod?() and not escript_mode?() do
      # In escript mode, Repo/Oban/Endpoint are skipped, so DB/secret
      # validation is unnecessary. The supervision tree degrades gracefully.
      _ = secret_key_base()
      _ = database_path()
      :ok
    else
      :ok
    end
  end

  @doc "Load config from env into a keyword list for `config/runtime.exs`."
  @spec load_from_env() :: keyword()
  def load_from_env do
    if prod?() do
      validate!()

      [
        {CodePuppyControlWeb.Endpoint, [secret_key_base: secret_key_base()]},
        {CodePuppyControl.Repo, [database: database_path()]},
        {:history_limit, history_limit()}
      ]
    else
      [
        {:history_limit, history_limit()}
      ]
    end
  end

  # ── Facade: delegations to sub-modules ──────────────────────────────────
  # Keep backward-compatible function names pointing at the right submodule.

  # Paths (constants)
  @deprecated "Use CodePuppyControl.Config.Paths functions directly"
  def config_dir, do: Paths.config_dir()
  @deprecated "Use CodePuppyControl.Config.Paths functions directly"
  def data_dir, do: Paths.data_dir()
  @deprecated "Use CodePuppyControl.Config.Paths functions directly"
  def cache_dir, do: Paths.cache_dir()
  @deprecated "Use CodePuppyControl.Config.Paths functions directly"
  def state_dir, do: Paths.state_dir()
  @deprecated "Use CodePuppyControl.Config.Paths functions directly"
  def config_file, do: Paths.config_file()

  # Agents
  @deprecated "Use CodePuppyControl.Config.Agents.default_agent/0"
  def get_default_agent, do: Agents.default_agent()
  @deprecated "Use CodePuppyControl.Config.Agents.set_default_agent/1"
  def set_default_agent(name), do: Agents.set_default_agent(name)
  @deprecated "Use CodePuppyControl.Config.Agents.puppy_name/0"
  def get_puppy_name, do: Agents.puppy_name()
  @deprecated "Use CodePuppyControl.Config.Agents.owner_name/0"
  def get_owner_name, do: Agents.owner_name()
  @deprecated "Use CodePuppyControl.Config.Agents.user_agents_dir/0"
  def get_user_agents_directory, do: Agents.user_agents_dir()

  # Models
  @deprecated "Use CodePuppyControl.Config.Models.global_model_name/0"
  def get_global_model_name, do: Models.global_model_name()
  @deprecated "Use CodePuppyControl.Config.Models.set_global_model/1"
  def set_model_name(model), do: Models.set_global_model(model)
  @deprecated "Use CodePuppyControl.Config.Models.agent_pinned_model/1"
  def get_agent_pinned_model(agent), do: Models.agent_pinned_model(agent)
  @deprecated "Use CodePuppyControl.Config.Models.set_agent_pinned_model/2"
  def set_agent_pinned_model(agent, model), do: Models.set_agent_pinned_model(agent, model)
  @deprecated "Use CodePuppyControl.Config.Models.clear_agent_pinned_model/1"
  def clear_agent_pinned_model(agent), do: Models.clear_agent_pinned_model(agent)
  @deprecated "Use CodePuppyControl.Config.Models.all_agent_pinned_models/0"
  def get_all_agent_pinned_models, do: Models.all_agent_pinned_models()

  # TUI
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def get_banner_color(name), do: TUI.banner_color(name)
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def set_banner_color(name, color), do: TUI.set_banner_color(name, color)
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def get_diff_addition_color, do: TUI.diff_addition_color()
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def set_diff_addition_color(color), do: TUI.set_diff_addition_color(color)
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def get_diff_deletion_color, do: TUI.diff_deletion_color()
  @deprecated "Use CodePuppyControl.Config.TUI functions directly"
  def set_diff_deletion_color(color), do: TUI.set_diff_deletion_color(color)

  # Limits
  @deprecated "Use CodePuppyControl.Config.Limits functions directly"
  def get_protected_token_count, do: Limits.protected_token_count()
  @deprecated "Use CodePuppyControl.Config.Limits functions directly"
  def get_compaction_threshold, do: Limits.compaction_threshold()
  @deprecated "Use CodePuppyControl.Config.Limits functions directly"
  def get_compaction_strategy, do: Limits.compaction_strategy()
  @deprecated "Use CodePuppyControl.Config.Limits functions directly"
  def get_message_limit, do: Limits.message_limit()
  @deprecated "Use CodePuppyControl.Config.Limits functions directly"
  def get_resume_message_count, do: Limits.resume_message_count()

  # Debug / feature toggles
  @deprecated "Use CodePuppyControl.Config.Debug functions directly"
  def get_yolo_mode, do: Debug.yolo_mode?()
  @deprecated "Use CodePuppyControl.Config.Debug functions directly"
  def get_temperature, do: Models.temperature()
  @deprecated "Use CodePuppyControl.Config.Debug functions directly"
  def set_temperature(val), do: Models.set_temperature(val)
  @deprecated "Use CodePuppyControl.Config.Debug functions directly"
  def load_api_keys_to_environment, do: Debug.load_api_keys_to_environment()

  # ── Ensure config exists ───────────────────────────────────────────────

  @doc """
  Ensure all XDG directories and `puppy.cfg` exist.
  If required keys (`puppy_name`, `owner_name`) are missing, prompts the user.
  """
  @spec ensure_config_exists() :: :ok
  def ensure_config_exists do
    Paths.ensure_dirs!()

    config = Loader.get_cached()
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})

    missing =
      for key <- ["puppy_name", "owner_name"],
          is_nil(section_map[key]) or section_map[key] == "",
          do: key

    if missing != [] do
      IO.puts("🐾 Let's get your Puppy ready!")

      updated_section =
        Enum.reduce(missing, section_map, fn key, acc ->
          prompt =
            case key do
              "puppy_name" -> "What should we name the puppy? "
              "owner_name" -> "What's your name (so Code Puppy knows its owner)? "
              other -> "Enter #{other}: "
            end

          value = IO.gets(prompt) |> to_string() |> String.trim()
          Map.put(acc, key, value)
        end)

      updated_config = Map.put(config, section, updated_section)
      Writer.write_config(updated_config)
    end

    :ok
  end

  # ── Migrator delegation ────────────────────────────────────────────────

  @doc "Run pending schema migrations on `puppy.cfg`."
  @spec migrate() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def migrate, do: Migrator.migrate()

  # Test-friendly indirection over `:filename.basedir(:user_data, "code_puppy")`.
  #
  # In production, this always returns the platform-default user-data dir.
  # Tests can inject a temp dir via:
  #
  # Application.put_env(:code_puppy_control, :user_data_dir_override, tmp_dir)
  #
  # This avoids writing real `secret_key_base` / `data.sqlite` files to the
  # CI runner's home directory.
  @spec user_data_dir() :: String.t()
  defp user_data_dir do
    case Application.get_env(:code_puppy_control, :user_data_dir_override) do
      override when is_binary(override) and byte_size(override) > 0 -> override
      _ -> :filename.basedir(:user_data, "code_puppy") |> to_string()
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp get_string_with_legacy(new_var, legacy_var, default) do
    case System.get_env(new_var) do
      nil ->
        case System.get_env(legacy_var) do
          nil ->
            default

          value ->
            if prod?() do
              Logger.warning(
                "Environment variable #{legacy_var} is deprecated. " <>
                  "Please migrate to #{new_var}."
              )
            end

            value
        end

      value ->
        value
    end
  end

  defp parse_integer_env(var_name, default) do
    case System.get_env(var_name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} ->
            int

          _ ->
            Logger.warning(
              "Invalid integer value for #{var_name}: #{value}, using default #{default}"
            )

            default
        end
    end
  end
end
