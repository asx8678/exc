defmodule CodePuppyControl.Plugins.Loader do
  @moduledoc """
  Discovers and loads plugins from builtin and user directories.

  Per ADR-006, the loader auto-discovers `register_callbacks.ex` and
  `register_callbacks.exs` files under:

  - **Builtin**: `priv/plugins/<name>/` (shipped with the application)
  - **User**: `~/.code_puppy_ex/plugins/<name>/` (user-installed)

  ## Plugin Types

  ### Builtin Compiled Plugins
  Modules in `CodePuppyControl.Plugins.*` that implement
  `CodePuppyControl.Plugins.PluginBehaviour`. Discovered at runtime
  in three phases:

  1. **Application module loading** — `Application.spec/2` enumerates
     all modules in `:code_puppy_control`; `Code.ensure_loaded?/1`
     loads each one so they appear in `:code.all_loaded/0`.
  2. **Behaviour scan** — `:code.all_loaded/0` is filtered for modules
     declaring `@behaviour PluginBehaviour`.
  3. **Explicit registry fallback** — `@builtin_plugin_modules` is
     checked as a safety net for release contexts where
     `Application.spec/2` may be unavailable.

  ### Builtin `priv/plugins/` Plugins
  `.ex` or `.exs` files under `priv/plugins/<name>/register_callbacks.*`.
  These are compiled (`.ex`) or evaluated (`.exs`) at runtime.
  See ADR-006 D2 for the static-vs-dynamic compilation decision.

  ### User Plugins
  `.ex` or `.exs` files under `~/.code_puppy_ex/plugins/<name>/`
  that are compiled/evaluated at runtime.

  **SECURITY WARNING**: User plugins execute arbitrary Elixir code with full
  system privileges. A malicious plugin can perform any action the host process
  can perform (delete files, steal credentials, install malware, etc.).
  Only load plugins from trusted sources.

  ## File Discovery Priority

  Per plugin directory, files are discovered in this order:

  1. `register_callbacks.ex`   — preferred (compiled to BEAM)
  2. `register_callbacks.exs`  — fallback (evaluated as script)
  3. Any other `.ex` file       — alphabetically
  4. Any other `.exs` file      — alphabetically

  When both `register_callbacks.ex` and `register_callbacks.exs` exist,
  the `.ex` file takes precedence.

  ## Compilation Semantics

  | Extension | Function          | BEAM  | Use Case                  |
  |-----------|-------------------|-------|---------------------------|
  | `.ex`     | `Code.compile_file/1` | ✅  | Proper modules with behaviours |
  | `.exs`    | `Code.eval_file/1`    | ❌  | Scripts that define a `PluginBehaviour` module (no `.beam`) |

  ## Discovery

  The loader scans for plugin modules and `.ex`/`.exs` files, then registers
  them with the callback system. Discovery is idempotent — calling
  `load_all/0` multiple times only discovers new plugins.
  """

  require Logger

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Plugins.Loader.Discovery

  # ── Explicit Builtin Plugin Registry ─────────────────────────────
  # Safety net: these modules are always proactively loaded regardless
  # of whether Application.spec/2 or :code.all_loaded/0 discovers them.
  # Add new compiled PluginBehaviour modules here when they are created.
  # This ensures OAuth and other critical plugins activate without
  # relying on incidental prior loading.
  @builtin_plugin_modules [
    CodePuppyControl.Plugins.ChatGptOAuth,
    CodePuppyControl.Plugins.ClaudeCodeOAuth,
    CodePuppyControl.Plugins.Motd,
    CodePuppyControl.Plugins.CostEstimator,
    CodePuppyControl.Plugins.ErrorClassifier,
    CodePuppyControl.Plugins.GitAutoCommit,
    CodePuppyControl.Plugins.FastPuppy,
    CodePuppyControl.Plugins.FileMentions,
    CodePuppyControl.Plugins.LoopDetection,
    CodePuppyControl.Plugins.AgentMemory,
    CodePuppyControl.Plugins.AgentTrace
  ]

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Discovers and loads all plugins (builtin + user).

  Returns a map with `:builtin` and `:user` keys containing lists of
  plugin names that were loaded.

  This function is idempotent — subsequent calls only discover new plugins.
  """
  @spec load_all() :: %{builtin: [atom()], user: [atom()]}
  def load_all do
    builtin = load_builtin_plugins()
    user = load_user_plugins()

    %{builtin: builtin, user: user}
  end

  @doc """
  Loads a single plugin from the given path.

  - For **module atoms**: directly loads if it implements `PluginBehaviour`.
  - For **`.ex` files**: compiles via `Code.compile_file/1`, discovers
    `PluginBehaviour` modules in the compiled output.
  - For **`.exs` files**: evaluates via `Code.eval_file/1`, discovers
    `PluginBehaviour` modules that were defined during evaluation.

  Returns `{:ok, plugin_name}` or `{:error, reason}`.
  """
  @spec load_plugin(String.t() | atom()) :: {:ok, atom()} | {:error, term()}
  def load_plugin(path_or_module)

  def load_plugin(module_name) when is_atom(module_name) do
    if Discovery.plugin_behaviour?(module_name) do
      register_plugin(module_name)
      {:ok, module_name.name()}
    else
      {:error, {:not_a_plugin, module_name}}
    end
  end

  def load_plugin(file_path) when is_binary(file_path) do
    expanded = Path.expand(file_path)

    if not File.exists?(expanded) do
      {:error, {:file_not_found, expanded}}
    else
      Logger.warning(
        "SECURITY: Loading user plugin from #{expanded} — executes arbitrary Elixir code " <>
          "with full system privileges. Only load plugins from trusted sources!"
      )

      try do
        load_plugin_file(expanded)
      rescue
        e ->
          Logger.error("Failed to load plugin from #{expanded}: #{Exception.message(e)}")
          {:error, {:compile_error, Exception.message(e)}}
      end
    end
  end

  @doc """
  Returns the path to the user plugins directory.
  """
  @spec user_plugins_dir() :: String.t()
  def user_plugins_dir, do: Paths.plugins_dir()

  @doc """
  Ensures the user plugins directory exists.

  Returns the path to the directory.
  """
  @spec ensure_user_plugins_dir() :: String.t()
  def ensure_user_plugins_dir do
    dir = Paths.plugins_dir()
    Isolation.safe_mkdir_p!(dir)
    dir
  end

  @doc """
  Lists all currently loaded plugins.

  Returns a list of maps with `:name`, `:module`, and `:type` keys.
  """
  @spec list_loaded() :: [%{name: atom(), module: module(), type: :builtin | :user}]
  def list_loaded do
    case :ets.whereis(__MODULE__) do
      :undefined -> []
      _tab -> __MODULE__ |> :ets.tab2list() |> Enum.map(fn {_k, v} -> v end)
    end
  end

  # Delegated discovery helpers (exposed for testability)

  @doc "Delegates to `Discovery.discover_plugin_files/1`."
  @spec discover_plugin_files(String.t()) :: [String.t()]
  def discover_plugin_files(plugin_dir), do: Discovery.discover_plugin_files(plugin_dir)

  @doc "Loads and registers a plugin file, delegating to Discovery."
  @spec load_and_register_plugin_file(String.t(), :builtin | :user) :: [atom()]
  def load_and_register_plugin_file(file_path, type) do
    Discovery.load_and_register_plugin_file(file_path, type, &register_plugin/2)
  end

  @doc "Ensures all modules for the given OTP application are loaded."
  @spec ensure_app_modules_loaded(atom()) :: [module()]
  def ensure_app_modules_loaded(app), do: Discovery.ensure_app_modules_loaded(app)

  # ── File Loading ─────────────────────────────────────────────────

  @spec load_plugin_file(String.t()) :: {:ok, atom()} | {:error, term()}
  defp load_plugin_file(file_path) do
    if String.ends_with?(file_path, ".exs") do
      Discovery.load_exs_plugin(file_path, &register_plugin/1)
    else
      Discovery.load_ex_plugin(file_path, &register_plugin/1)
    end
  end

  # ── Builtin Plugin Discovery ────────────────────────────────────

  @spec load_builtin_plugins() :: [atom()]
  defp load_builtin_plugins do
    ensure_ets_table()

    loaded_names =
      list_loaded()
      |> Enum.map(& &1.name)
      |> normalize_names()

    # Phase 1: Proactively load all application modules so that
    # compiled PluginBehaviour implementations are visible to
    # :code.all_loaded/0. Without this, modules like ChatGptOAuth
    # and ClaudeCodeOAuth may be absent from :code.all_loaded/0
    # if nothing else has referenced them yet.
    _ = Discovery.ensure_app_modules_loaded(:code_puppy_control)

    # Phase 2: Scan all loaded modules for PluginBehaviour implementations
    module_names =
      :code.all_loaded()
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.filter(&Discovery.plugin_behaviour?/1)
      |> Enum.reject(&already_loaded?(&1, loaded_names))
      |> Enum.map(fn mod ->
        register_plugin(mod, :builtin)
        mod.name()
      end)

    # Phase 3: Safety net — explicitly ensure builtin plugin modules from
    # the registry are loaded. This catches any modules that Phase 1/2
    # missed (e.g. in release contexts where Application.spec/2 is
    # unavailable or incomplete).
    # Normalize names to strings for robust dedup (name/0 may return atom or string).
    phase2_names = MapSet.new(module_names, &to_string/1)

    registry_names =
      @builtin_plugin_modules
      |> Enum.filter(&Discovery.plugin_behaviour?/1)
      |> Enum.reject(&already_loaded?(&1, loaded_names))
      |> Enum.reject(fn mod -> MapSet.member?(phase2_names, to_string(mod.name())) end)
      |> Enum.map(fn mod ->
        register_plugin(mod, :builtin)
        mod.name()
      end)

    # Discover builtin plugins in priv/plugins/
    priv_names = load_priv_plugins(loaded_names)

    Enum.uniq(module_names ++ registry_names ++ priv_names)
  end

  @spec load_priv_plugins(MapSet.t()) :: [atom()]
  defp load_priv_plugins(loaded_names) do
    priv_dir = priv_plugins_dir()

    unless File.dir?(priv_dir) do
      []
    else
      priv_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        dir = Path.join(priv_dir, name)

        File.dir?(dir) and
          not String.starts_with?(name, "_") and
          not String.starts_with?(name, ".")
      end)
      |> Enum.flat_map(fn plugin_name ->
        normalized = plugin_name |> String.replace("-", "_")

        if MapSet.member?(loaded_names, normalized) do
          []
        else
          load_priv_plugin(plugin_name, priv_dir)
        end
      end)
    end
  end

  @spec load_priv_plugin(String.t(), String.t()) :: [atom()]
  defp load_priv_plugin(plugin_name, plugins_dir) do
    plugin_dir = Path.join(plugins_dir, plugin_name)
    plugin_files = Discovery.discover_plugin_files(plugin_dir)

    case plugin_files do
      [] ->
        Logger.debug("No .ex/.exs files found in priv plugin: #{plugin_name}")
        []

      files ->
        Enum.flat_map(files, fn file ->
          try do
            Discovery.load_and_register_plugin_file(file, :builtin, &register_plugin/2)
          rescue
            e ->
              Logger.error("Failed to load priv plugin '#{plugin_name}': #{Exception.message(e)}")
              []
          end
        end)
    end
  end

  @doc """
  Returns the path to the priv/plugins/ directory for builtin plugins.
  """
  @spec priv_plugins_dir() :: String.t()
  def priv_plugins_dir do
    :code.priv_dir(:code_puppy_control)
    |> to_string()
    |> Path.join("plugins")
  rescue
    _ ->
      Path.join([File.cwd!(), "priv", "plugins"])
  end

  # ── User Plugin Discovery ───────────────────────────────────────

  @spec load_user_plugins() :: [atom()]
  defp load_user_plugins do
    ensure_ets_table()

    plugins_dir = Paths.plugins_dir()

    unless File.dir?(plugins_dir) do
      []
    else
      loaded_names =
        list_loaded()
        |> Enum.map(& &1.name)
        |> normalize_names()

      plugins_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        dir = Path.join(plugins_dir, name)

        File.dir?(dir) and not String.starts_with?(name, "_") and
          not String.starts_with?(name, ".")
      end)
      |> Enum.flat_map(fn plugin_name ->
        if MapSet.member?(loaded_names, to_string(plugin_name)) do
          []
        else
          load_user_plugin(plugin_name, plugins_dir)
        end
      end)
    end
  end

  @spec load_user_plugin(String.t(), String.t()) :: [atom()]
  defp load_user_plugin(plugin_name, plugins_dir) do
    plugin_dir = Path.join(plugins_dir, plugin_name)

    if String.contains?(plugin_name, ["..", "/", "\\", <<0>>]) do
      Logger.warning("SECURITY: Skipping user plugin with suspicious name: #{plugin_name}")
      []
    else
      # Guard against the plugin directory itself being a symlink
      # that escapes the plugins base (e.g. evil_plugin → /tmp/escape).
      unless safe_plugin_path?(plugin_dir, plugins_dir) do
        Logger.warning(
          "SECURITY: Skipping user plugin '#{plugin_name}' — " <>
            "directory canonical path escapes plugins directory"
        )

        []
      else
        plugin_files = Discovery.discover_plugin_files(plugin_dir)

        safe_files =
          Enum.filter(plugin_files, fn file ->
            if safe_plugin_path?(file, plugins_dir) do
              true
            else
              Logger.warning(
                "SECURITY: Skipping user plugin file #{file} — canonical path escapes plugins directory"
              )

              false
            end
          end)

        case safe_files do
          [] ->
            Logger.warning("No .ex/.exs files found in user plugin: #{plugin_name}")
            []

          files ->
            Enum.flat_map(files, fn file ->
              Logger.warning(
                "SECURITY: Loading user plugin '#{plugin_name}' from #{file} — " <>
                  "executes arbitrary Elixir code with full system privileges!"
              )

              try do
                Discovery.load_and_register_plugin_file(file, :user, &register_plugin/2)
              rescue
                e ->
                  Logger.error(
                    "Failed to load user plugin '#{plugin_name}': #{Exception.message(e)}"
                  )

                  []
              end
            end)
        end
      end
    end
  end

  # ── Plugin Registration ─────────────────────────────────────────

  @spec register_plugin(module(), :builtin | :user) :: :ok
  defp register_plugin(module, type \\ :builtin) do
    ensure_ets_table()

    plugin_info = %{
      name: module.name(),
      module: module,
      type: type
    }

    :ets.insert(__MODULE__, {module.name(), plugin_info})

    # Prefer register/0 over register_callbacks/0
    # Errors from register/0 are caught so a broken plugin
    # cannot crash the host application.
    cond do
      function_exported?(module, :register, 0) ->
        try do
          case module.register() do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "Plugin #{module.name()} register/0 returned error: #{inspect(reason)}"
              )

            other ->
              Logger.warning(
                "Plugin #{module.name()} register/0 returned unexpected: #{inspect(other)}"
              )
          end
        rescue
          e ->
            Logger.error("Plugin #{module.name()} register/0 raised: #{Exception.message(e)}")
        catch
          kind, reason ->
            Logger.error(
              "Plugin #{module.name()} register/0 crashed: #{Exception.format(kind, reason)}"
            )
        end

      function_exported?(module, :register_callbacks, 0) ->
        # Crash isolation: catch errors so a broken plugin cannot
        # crash the host or prevent later plugins from loading.
        try do
          callbacks = module.register_callbacks()

          Enum.each(callbacks, fn {hook_name, fun} ->
            try do
              Callbacks.register(hook_name, fun)
            rescue
              ArgumentError ->
                Logger.warning(
                  "Plugin #{module.name()} registered callback for unknown hook: #{hook_name}"
                )
            end
          end)
        rescue
          e ->
            Logger.error(
              "Plugin #{module.name()} register_callbacks/0 raised: #{Exception.message(e)}"
            )
        end

      true ->
        Logger.warning(
          "Plugin #{module.name()} implements neither register/0 nor register_callbacks/0"
        )
    end

    if function_exported?(module, :startup, 0) do
      # Crash isolation: startup/0 errors must not crash the host or
      # prevent later plugins from loading.
      try do
        module.startup()
      rescue
        e ->
          Logger.error("Plugin #{module.name()} startup/0 raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error(
            "Plugin #{module.name()} startup/0 crashed: #{Exception.format(kind, reason)}"
          )
      end
    end

    Logger.info("Loaded #{type} plugin: #{module.name()}")
    :ok
  end

  # ── Security Helpers ─────────────────────────────────────────────

  @spec normalize_names([atom() | String.t()]) :: MapSet.t(String.t())
  defp normalize_names(names) do
    MapSet.new(names, &to_string/1)
  end

  @spec already_loaded?(module(), MapSet.t(String.t())) :: boolean()
  defp already_loaded?(module, loaded_names) do
    name = to_string(module.name())
    MapSet.member?(loaded_names, name)
  end

  @doc """
  Checks that the canonical (resolved) path of `path` stays within `base_dir`.

  This prevents path-traversal attacks via symlinks that point outside the
  expected directory tree. Symlinks are followed recursively so that a
  symlink inside the plugins dir pointing to a file outside is rejected.
  """
  @spec safe_plugin_path?(String.t(), String.t()) :: boolean()
  def safe_plugin_path?(path, base_dir) do
    # Use Paths.canonical_resolve/1 which walks ALL intermediate directory
    # symlinks, not just the final path component. This prevents attacks
    # where an intermediate directory in the path is a symlink pointing
    # outside the plugins base (e.g. plugin_dir → /tmp/escape).
    canonical = Paths.canonical_resolve(path)
    canonical_base = Paths.canonical_resolve(base_dir)
    canonical == canonical_base or String.starts_with?(canonical, canonical_base <> "/")
  end

  # ── ETS Table Management ────────────────────────────────────────

  @spec ensure_ets_table() :: :ok
  defp ensure_ets_table do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        :ets.new(__MODULE__, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
