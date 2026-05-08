defmodule CodePuppyControl.Plugins.Loader.Discovery do
  @moduledoc """
  Shared plugin file discovery and loading helpers.

  Extracted from `CodePuppyControl.Plugins.Loader` per the 600-line file cap.
  These functions implement the ADR-006 plugin file discovery priority and
  compilation/evaluation logic shared by builtin and user plugin loading.
  """

  require Logger

  alias CodePuppyControl.Plugins.PluginBehaviour

  # ── File Discovery ───────────────────────────────────────────────

  @doc """
  Discovers plugin files in a plugin directory per ADR-006 priority.

  Priority order:
  1. `register_callbacks.ex`  — preferred (compiled to BEAM)
  2. `register_callbacks.exs` — fallback (evaluated as script)
  3. Any other `.ex` files   — alphabetically
  4. Any other `.exs` files  — alphabetically

  Returns a list of absolute file paths, or `[]` if none found.
  """
  @spec discover_plugin_files(String.t()) :: [String.t()]
  def discover_plugin_files(plugin_dir) do
    rc_ex = Path.join(plugin_dir, "register_callbacks.ex")
    rc_exs = Path.join(plugin_dir, "register_callbacks.exs")

    cond do
      File.exists?(rc_ex) ->
        [rc_ex]

      File.exists?(rc_exs) ->
        [rc_exs]

      true ->
        # Fallback: scan for .ex and .exs files alphabetically
        # .ex files before .exs files (same priority principle)
        case File.ls(plugin_dir) do
          {:ok, entries} ->
            ex_files =
              entries
              |> Enum.filter(&String.ends_with?(&1, ".ex"))
              |> Enum.sort()
              |> Enum.map(&Path.join(plugin_dir, &1))

            exs_files =
              entries
              |> Enum.filter(&String.ends_with?(&1, ".exs"))
              |> Enum.sort()
              |> Enum.map(&Path.join(plugin_dir, &1))

            ex_files ++ exs_files

          {:error, _} ->
            []
        end
    end
  end

  # ── File Loading ─────────────────────────────────────────────────

  @doc """
  Loads a single plugin file (.ex or .exs), discovers PluginBehaviour
  modules, and registers them.

  Returns a list of plugin name atoms that were loaded.
  """
  @spec load_and_register_plugin_file(String.t(), :builtin | :user, function()) :: [atom()]
  def load_and_register_plugin_file(file_path, type, register_fn) do
    modules_before = loaded_modules()

    if String.ends_with?(file_path, ".exs") do
      Code.eval_file(file_path)
    else
      Code.compile_file(file_path)
    end

    modules_after = loaded_modules()
    new_modules = modules_after -- modules_before

    plugin_modules = Enum.filter(new_modules, &plugin_behaviour?/1)

    Enum.map(plugin_modules, fn mod ->
      register_fn.(mod, type)
      mod.name()
    end)
  end

  @doc """
  Loads a single `.ex` plugin file and returns the result.

  Used by `load_plugin/1` for direct file loading.
  """
  @spec load_ex_plugin(String.t(), function()) :: {:ok, atom()} | {:error, term()}
  def load_ex_plugin(file_path, register_fn) do
    modules_before = loaded_modules()
    Code.compile_file(file_path)
    modules_after = loaded_modules()
    new_modules = modules_after -- modules_before

    plugin_modules = Enum.filter(new_modules, &plugin_behaviour?/1)

    case plugin_modules do
      [] ->
        {:error, {:no_plugins_found, file_path}}

      [mod | _] ->
        register_fn.(mod)
        {:ok, mod.name()}
    end
  end

  @doc """
  Loads a single `.exs` plugin file and returns the result.

  Used by `load_plugin/1` for direct file loading.
  """
  @spec load_exs_plugin(String.t(), function()) :: {:ok, atom()} | {:error, term()}
  def load_exs_plugin(file_path, register_fn) do
    # TODO(code-puppy-154.1): Consider adding a compile guard that rejects
    # .exs files defining @behaviour modules that conflict with already-loaded
    # modules (module redefinition). For now, Code.eval_file/1 silently
    # redefines modules in the calling process scope.
    modules_before = loaded_modules()
    Code.eval_file(file_path)
    modules_after = loaded_modules()
    new_modules = modules_after -- modules_before

    plugin_modules = Enum.filter(new_modules, &plugin_behaviour?/1)

    case plugin_modules do
      [] ->
        {:error, {:no_plugins_found, file_path}}

      [mod | _] ->
        register_fn.(mod)
        {:ok, mod.name()}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  @doc false
  @spec plugin_behaviour?(module()) :: boolean()
  def plugin_behaviour?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get(:behaviour, [])

    PluginBehaviour in behaviours
  rescue
    UndefinedFunctionError -> false
    _ -> false
  end

  @doc false
  @spec loaded_modules() :: [module()]
  def loaded_modules do
    :code.all_loaded() |> Enum.map(fn {mod, _} -> mod end)
  end

  # ── Application Module Enumeration ─────────────────────────────

  @doc """
  Actively loads all modules belonging to the given OTP application
  via `Code.ensure_loaded?/1`, then returns the list of modules
  that were successfully loaded.

  This is necessary because `:code.all_loaded/0` only returns modules
  that have been *incidentally* loaded (referenced by other code).
  Compiled builtin plugins may not appear in `:code.all_loaded/0`
  if no other module has referenced them yet.

  Falls back to `:code.all_loaded/0` if `Application.spec/2` returns
  no modules (e.g. in some release contexts).
  """
  @spec ensure_app_modules_loaded(atom()) :: [module()]
  def ensure_app_modules_loaded(app) do
    case Application.spec(app, :modules) do
      nil ->
        Logger.debug(
          "Application spec for #{app} returned no modules; " <>
            "falling back to :code.all_loaded/0"
        )

        loaded_modules()

      modules when is_list(modules) ->
        Enum.each(modules, fn mod ->
          unless Code.ensure_loaded?(mod) do
            Logger.debug("Failed to ensure_loaded #{inspect(mod)}; skipping")
          end
        end)

        # After ensuring, re-scan all_loaded for completeness
        loaded_modules()

      other ->
        Logger.debug("Application spec for #{app} returned unexpected: #{inspect(other)}")
        loaded_modules()
    end
  end
end
