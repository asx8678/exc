defmodule CodePuppyControl.Plugins.PluginBehaviour do
  @moduledoc """
  Behaviour definition for Code Puppy plugins.

  Plugins implement this behaviour to register callbacks, provide metadata,
  and participate in the plugin lifecycle (startup/shutdown).

  ## Example

      defmodule MyPlugin do
        @behaviour CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "my_plugin"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:startup, fn ->
            IO.puts("MyPlugin loaded!")
          end)

          CodePuppyControl.Callbacks.register(:load_prompt, fn ->
            "## My Plugin Instructions"
          end)

          :ok
        end

        @impl true
        def startup, do: :ok

        @impl true
        def shutdown, do: :ok
      end

  ## Using the `use` Macro

  You can `use` this module to get default implementations for optional
  callbacks:

      defmodule MyPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "my_plugin"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:startup, fn -> :ok end)
          :ok
        end
      end

  ## Migration from register_callbacks/0

  The older `register_callbacks/0` callback (returning a list of
  `{hook, fun}` tuples) is still supported for backward compatibility,
  but new plugins should prefer `register/0` which registers callbacks
  directly with `Callbacks.register/2`. This gives plugins full control
  over registration and avoids the indirection of tuple lists.

  If both `register/0` and `register_callbacks/0` are defined,
  `register/0` takes precedence.
  """

  # ── Required Callbacks ──────────────────────────────────────────
  @doc """
  Returns the unique name/identifier for this plugin.

  Can be a string or an atom. Strings are preferred for new plugins.
  """
  @callback name() :: String.t() | atom()

  @doc """
  Registers this plugin's callbacks with the callback system.

  Called during plugin loading. Implementations should call
  `Callbacks.register/2` directly to hook into the desired events.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback register() :: :ok | {:error, term()}

  # ── Optional Callbacks ──────────────────────────────────────────

  @doc """
  Called when the plugin system starts up. Optional — defaults to `:ok`.
  """
  @callback startup() :: :ok

  @doc """
  Called when the plugin system shuts down. Optional — defaults to `:ok`.
  """
  @callback shutdown() :: :ok

  @doc """
  Returns a description of the plugin. Optional — defaults to `""`.
  """
  @callback description() :: String.t()

  @doc """
  Returns a list of `{hook_name, callback_fn}` tuples to register.

  **DEPRECATED**: Prefer `register/0` which calls `Callbacks.register/2`
  directly. This callback is retained for backward compatibility with
  existing plugins.

  Each `hook_name` must be a valid hook from `CodePuppyControl.Callbacks.Hooks`.
  Each `callback_fn` is a function matching the hook's expected arity.
  """
  @callback register_callbacks() :: [{atom(), function()}]

  @optional_callbacks [startup: 0, shutdown: 0, description: 0, register_callbacks: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour CodePuppyControl.Plugins.PluginBehaviour

      @impl true
      def startup, do: :ok

      @impl true
      def shutdown, do: :ok

      @impl true
      def description, do: ""

      defoverridable startup: 0, shutdown: 0, description: 0
    end
  end
end
