defmodule CodePuppyControl.Plugins do
  @moduledoc """
  Public API for the plugin loading system.

  Plugins extend Code Puppy's functionality by registering callback
  hooks for various lifecycle events and extension points.

  ## Quick Start

      # Load all plugins (builtin + user)
      CodePuppyControl.Plugins.load_all()

      # List loaded plugins
      CodePuppyControl.Plugins.list_loaded()

      # Load a single plugin
      CodePuppyControl.Plugins.load_plugin(MyPlugin)
      CodePuppyControl.Plugins.load_plugin("/path/to/plugin.ex")

  ## Plugin Types

  ### Builtin Plugins
  Compiled modules that implement `CodePuppyControl.Plugins.PluginBehaviour`.
  These are modules linked at compile time under the `CodePuppyControl.Plugins.*`
  namespace.

  ### User Plugins
  `.ex` or `.exs` files under `~/.code_puppy_ex/plugins/` that are
  compiled/evaluated at runtime.

  Per ADR-006, `register_callbacks.ex` is preferred (compiled to BEAM).
  `register_callbacks.exs` is supported as a fallback (evaluated as script).

  **SECURITY WARNING**: User plugins execute arbitrary Elixir code with full
  system privileges. Only load plugins from trusted sources.

  ## Lifecycle

  1. `load_all()` discovers builtin and user plugins
  2. Each plugin's `register/0` is called to register callbacks with the system
  3. Each plugin's `startup/0` is called (if defined)
  4. On shutdown, each plugin's `shutdown/0` is called (if defined)

  ## Example Plugin Structure

  A user plugin at `~/.code_puppy_ex/plugins/my_plugin/register_callbacks.ex`:

      defmodule CodePuppyControl.Plugins.MyPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "my_plugin"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:startup, fn ->
            IO.puts("MyPlugin loaded!")
          end)

          CodePuppyControl.Callbacks.register(:load_prompt, fn ->
            "## My Instructions"
          end)

          :ok
        end
      end
  """

  require Logger

  alias CodePuppyControl.Plugins.Loader

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Discovers and loads all plugins from builtin and user directories.

  Returns a map with `:builtin` and `:user` keys listing loaded plugin names.

  This function is idempotent — safe to call multiple times.

  ## Examples

      %{builtin: [:shell_safety], user: [:my_plugin]} = CodePuppyControl.Plugins.load_all()
  """
  @spec load_all() :: %{builtin: [atom()], user: [atom()]}
  def load_all do
    Loader.load_all()
  end

  @doc """
  Loads a single plugin from a module or file path.

  - If given an atom: loads the module directly (must implement PluginBehaviour)
  - If given a string: compiles the `.ex` file and loads any PluginBehaviour modules

  Returns `{:ok, plugin_name}` or `{:error, reason}`.

  ## Examples

      {:ok, :my_plugin} = CodePuppyControl.Plugins.load_plugin(MyPlugin)
      {:ok, :my_plugin} = CodePuppyControl.Plugins.load_plugin("/path/to/plugin.ex")
  """
  @spec load_plugin(String.t() | atom()) :: {:ok, atom()} | {:error, term()}
  def load_plugin(path_or_module) do
    Loader.load_plugin(path_or_module)
  end

  @doc """
  Lists all currently loaded plugins.

  Returns a list of maps with `:name`, `:module`, and `:type` keys.

  ## Examples

      CodePuppyControl.Plugins.list_loaded()
      #=> [%{name: :my_plugin, module: MyPlugin, type: :builtin}]
  """
  @spec list_loaded() :: [%{name: atom(), module: module(), type: :builtin | :user}]
  def list_loaded do
    Loader.list_loaded()
  end

  @doc """
  Returns the path to the user plugins directory.

  ## Examples

      CodePuppyControl.Plugins.user_plugins_dir()
      #=> "/home/user/.code_puppy/plugins"
  """
  @spec user_plugins_dir() :: String.t()
  def user_plugins_dir do
    Loader.user_plugins_dir()
  end

  @doc """
  Ensures the user plugins directory exists.

  Returns the path to the directory.
  """
  @spec ensure_user_plugins_dir() :: String.t()
  def ensure_user_plugins_dir do
    Loader.ensure_user_plugins_dir()
  end
end
