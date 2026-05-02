defmodule CodePuppyControl.Config.Paths do
  @moduledoc """
  XDG-compatible path resolution for Code Puppy directories and files.

  Implements ADR-003 dual-home config isolation. The Elixir pup-ex runtime
  uses `~/.code_puppy_ex/` as its home, separate from the Python pup's
  `~/.code_puppy/`. Writes to the legacy home are blocked by the
  `CodePuppyControl.Config.Isolation` guard module.

  ## Home Resolution Priority

  1. `PUP_EX_HOME` env var — explicit Elixir home override
  2. `PUP_HOME` env var — legacy override (deprecation warning)
  3. `PUPPY_HOME` env var — oldest legacy override (deprecation warning)
  4. Default `~/.code_puppy_ex/` — standard fallback

  ## Path Layout

  ```
  ~/.code_puppy_ex/
  ├── puppy.cfg           # Main config (INI format)
  ├── mcp_servers.json    # MCP server definitions
  ├── models.json         # Model registry
  ├── extra_models.json   # User-added models
  ├── agents/             # Agent definitions
  ├── skills/             # Skill definitions
  ├── contexts/           # Context presets
  ├── autosaves/          # Session autosaves (cache)
  ├── command_history.txt # Command history (state)
  └── dbos_store.sqlite   # DBOS state store
  ```

  When XDG env vars are set, files split across config/data/cache/state
  directories per the spec. Otherwise everything lives under `~/.code_puppy_ex`.
  """

  require Logger

  @home_dir Path.expand("~")

  @max_symlink_depth 40

  # ── Base directories ────────────────────────────────────────────────────

  @doc """
  Root directory for all Elixir pup-ex files.

  Resolution order: `PUP_EX_HOME` → `PUP_HOME` (deprecated) →
  `PUPPY_HOME` (deprecated) → `~/.code_puppy_ex`.
  """
  @spec home_dir() :: String.t()
  def home_dir do
    cond do
      env = System.get_env("PUP_EX_HOME") ->
        env

      env = System.get_env("PUP_HOME") ->
        maybe_warn_deprecation("PUP_HOME")
        env

      env = System.get_env("PUPPY_HOME") ->
        maybe_warn_deprecation("PUPPY_HOME")
        env

      true ->
        Path.join(@home_dir, ".code_puppy_ex")
    end
  end

  @doc """
  Legacy home directory — always `~/.code_puppy`, regardless of env vars.

  This is the Python pup's home directory. Elixir pup-ex must NEVER write
  here. Use only for read-only import via `mix pup_ex.import`.

      read_only: true, legacy: true
  """
  @spec legacy_home_dir() :: String.t()
  def legacy_home_dir do
    Path.join(@home_dir, ".code_puppy")
  end

  @doc """
  Configuration directory. Contains `puppy.cfg`, `mcp_servers.json`.

  Uses `XDG_CONFIG_HOME/code_puppy_ex` if set, otherwise falls back to `home_dir/`.
  """
  @spec config_dir() :: String.t()
  def config_dir do
    xdg_dir("XDG_CONFIG_HOME")
  end

  @doc """
  Data directory. Contains `models.json`, `agents/`, `skills/`.

  Uses `XDG_DATA_HOME/code_puppy_ex` if set, otherwise falls back to `home_dir/`.
  """
  @spec data_dir() :: String.t()
  def data_dir do
    xdg_dir("XDG_DATA_HOME")
  end

  @doc """
  Cache directory. Contains autosaves and temporary data.

  Uses `XDG_CACHE_HOME/code_puppy_ex` if set, otherwise falls back to `home_dir/`.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    xdg_dir("XDG_CACHE_HOME")
  end

  @doc """
  State directory. Contains command history and persistent runtime state.

  Uses `XDG_STATE_HOME/code_puppy_ex` if set, otherwise falls back to `home_dir/`.
  """
  @spec state_dir() :: String.t()
  def state_dir do
    xdg_dir("XDG_STATE_HOME")
  end

  # ── Config files ────────────────────────────────────────────────────────

  @doc "Path to the main config file `puppy.cfg`."
  @spec config_file() :: String.t()
  def config_file, do: Path.join(config_dir(), "puppy.cfg")

  @doc "Path to the MCP servers config file."
  @spec mcp_servers_file() :: String.t()
  def mcp_servers_file, do: Path.join(config_dir(), "mcp_servers.json")

  # ── Data files ──────────────────────────────────────────────────────────

  @doc "Path to the model registry JSON file."
  @spec models_file() :: String.t()
  def models_file, do: Path.join(data_dir(), "models.json")

  @doc "Path to user-added extra models file."
  @spec extra_models_file() :: String.t()
  def extra_models_file, do: Path.join(data_dir(), "extra_models.json")

  @doc "Path to the agents directory."
  @spec agents_dir() :: String.t()
  def agents_dir, do: Path.join(data_dir(), "agents")

  @doc "Path to the skills directory."
  @spec skills_dir() :: String.t()
  def skills_dir, do: Path.join(data_dir(), "skills")

  @doc "Path to the contexts directory."
  @spec contexts_dir() :: String.t()
  def contexts_dir, do: Path.join(data_dir(), "contexts")

  # ── Plugin / policy paths ──────────────────────────────────────────────

  @doc """
  Path to the model packs JSON file.

  Used by `ModelPacks` to persist user-defined model packs.
  """
  @spec model_packs_file() :: String.t()
  def model_packs_file, do: Path.join(data_dir(), "model_packs.json")

  @doc """
  Path to the user plugins directory.

  Used by `Plugins.Loader` for runtime plugin discovery.
  """
  @spec plugins_dir() :: String.t()
  def plugins_dir, do: Path.join(home_dir(), "plugins")

  @doc """
  Path to the user-level policy JSON file.

  Used by `PolicyConfig` and `PolicyEngine` for user-wide policy rules.
  """
  @spec user_policy_file() :: String.t()
  def user_policy_file, do: Path.join(config_dir(), "policy.json")

  @doc """
  Path to the project-local policy JSON file.

  Resolved relative to the current working directory (`.code_puppy/policy.json`).
  This is per-project config, NOT subject to the isolation guard.
  """
  @spec project_policy_file() :: String.t()
  def project_policy_file, do: Path.join([File.cwd!(), ".code_puppy", "policy.json"])

  @doc """
  Path to the Universal Constructor tools directory.

  Used by UC create_action, registry, and facade modules.
  """
  @spec universal_constructor_dir() :: String.t()
  def universal_constructor_dir, do: Path.join(plugins_dir(), "universal_constructor")

  @doc """
  Path to the ChatGPT models overlay JSON file.

  Used by `ModelRegistry` to load ChatGPT OAuth model definitions.
  """
  @spec chatgpt_models_file() :: String.t()
  def chatgpt_models_file, do: Path.join(data_dir(), "chatgpt_models.json")

  @doc """
  Path to the Claude models overlay JSON file.

  Used by `ModelRegistry` to load Claude Code OAuth model definitions.
  """
  @spec claude_models_file() :: String.t()
  def claude_models_file, do: Path.join(data_dir(), "claude_models.json")

  @doc """
  Path to the encrypted credentials store directory.

  Contains `store.json` — the AES-256-GCM encrypted credential store
  managed by `CodePuppyControl.Credentials`.
  """
  @spec credentials_dir() :: String.t()
  def credentials_dir, do: Path.join(data_dir(), "credentials")

  # ── Cache files ─────────────────────────────────────────────────────────

  @doc "Path to the autosaves directory."
  @spec autosave_dir() :: String.t()
  def autosave_dir, do: Path.join(cache_dir(), "autosaves")

  # ── State files ─────────────────────────────────────────────────────────

  @doc "Path to the command history file."
  @spec command_history_file() :: String.t()
  def command_history_file, do: Path.join(state_dir(), "command_history.txt")

  # ── Canonical Path Resolution ───────────────────────────────────────────

  @doc """
  Resolve a path to its canonical form by following all symlinks.

  Walks each path component, resolving symlinks at every level. Returns the
  fully resolved path. If max symlink depth (40) is exceeded, returns the
  last successfully resolved path. If the path or any component doesn't
  exist, returns the `Path.expand/1` result (symlinks can only be followed
  for existing filesystem entries).
  """
  @spec canonical_resolve(Path.t()) :: String.t()
  def canonical_resolve(path) do
    expanded = Path.expand(path)
    walk_components(Path.split(expanded), [], 0)
  end

  defp walk_components(remaining, acc, depth) when depth >= @max_symlink_depth do
    join_accumulated(acc, remaining)
  end

  defp walk_components([], acc, _depth) do
    Path.join(Enum.reverse(acc))
  end

  defp walk_components([component | rest], acc, depth) do
    current =
      case acc do
        [] -> component
        _ -> Path.join(Enum.reverse([component | acc]))
      end

    case :file.read_link(current) do
      {:ok, target} ->
        resolved = resolve_symlink_target(current, target)
        new_components = Path.split(resolved) ++ rest
        walk_components(new_components, [], depth + 1)

      {:error, _} ->
        walk_components(rest, [component | acc], depth)
    end
  end

  defp resolve_symlink_target(source, target) do
    if Path.type(target) == :absolute do
      Path.expand(target)
    else
      source
      |> Path.dirname()
      |> Path.join(target)
      |> Path.expand()
    end
  end

  defp join_accumulated(acc, remaining) do
    Path.join(Enum.reverse(acc) ++ remaining)
  end

  # ── Legacy Home Detection ───────────────────────────────────────────────

  @doc """
  Returns `true` if the given path resolves to a location under the legacy
  home directory (`~/.code_puppy`).

  Performs canonical resolution (following symlinks) before comparison.
  This blocks symlink attacks where a path like `/tmp/link → ~/.code_puppy/x`
  would bypass the isolation guard.
  """
  @spec in_legacy_home?(Path.t()) :: boolean()
  def in_legacy_home?(path) do
    resolved = canonical_resolve(path)
    legacy = legacy_home_dir()
    resolved == legacy or String.starts_with?(resolved, legacy <> "/")
  end

  # ── Utilities ───────────────────────────────────────────────────────────

  @doc """
  Ensure all standard directories exist with `0o700` permissions.
  Returns `:ok`.
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    for dir <- [
          config_dir(),
          data_dir(),
          cache_dir(),
          state_dir(),
          skills_dir(),
          credentials_dir()
        ] do
      File.mkdir_p!(dir)
      # Best-effort permission set (no-op on some platforms)
      File.chmod(dir, 0o700)
    end

    :ok
  end

  @doc """
  Return a project-local agents directory if `.code_puppy/agents/` exists
  in the current working directory, or `nil`.
  """
  @spec project_agents_dir() :: String.t() | nil
  def project_agents_dir do
    path = Path.join(File.cwd!(), ".code_puppy/agents")
    if File.dir?(path), do: path, else: nil
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp xdg_dir(xdg_var) do
    cond do
      env = System.get_env("PUP_EX_HOME") ->
        env

      env = System.get_env("PUP_HOME") ->
        maybe_warn_deprecation("PUP_HOME")
        env

      true ->
        xdg_or_default(xdg_var)
    end
  end

  defp xdg_or_default(xdg_var) do
    case System.get_env(xdg_var) do
      nil ->
        case System.get_env("PUPPY_HOME") do
          nil ->
            Path.join(@home_dir, ".code_puppy_ex")

          home ->
            maybe_warn_deprecation("PUPPY_HOME")
            home
        end

      xdg_base ->
        Path.join(xdg_base, "code_puppy_ex")
    end
  end

  @doc false
  def maybe_warn_deprecation(env_var) do
    key = {:code_puppy_control, :deprecation_warned, env_var}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning("#{env_var} is deprecated for Elixir pup-ex. Use PUP_EX_HOME instead.")
    end

    :ok
  end
end
