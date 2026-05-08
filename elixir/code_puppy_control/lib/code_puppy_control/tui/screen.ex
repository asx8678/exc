defmodule CodePuppyControl.TUI.Screen do
  @moduledoc """
  Behaviour for TUI screens.

  Each screen implements three callbacks:

    * `init/1`   — build initial state from options
    * `render/1` — produce an `Owl.Data.t()` fragment for display
    * `handle_input/2` — react to user input, optionally navigating

  Screens are driven by `CodePuppyControl.TUI.App`, which owns the
  navigation stack and delegates input/render cycles to the active
  screen module.

  ## Lifecycle

      1. App calls `screen.init(opts)` → `{:ok, state}`
      2. App calls `screen.render(state)` → Owl.Data.t()
      3. On each keystroke/line: `screen.handle_input(input, state)`
         - `{:ok, new_state}`          → re-render with updated state
         - `{:switch, module, opts}`  → navigate to another screen
         - `:quit`                     → exit the TUI

  ## Example

      defmodule MyApp.HomeScreen do
        @behaviour CodePuppyControl.TUI.Screen

        @impl true
        def init(_opts), do: {:ok, %{title: "Home"}}

        @impl true
        def render(state) do
          Owl.Data.tag("🏠 \#{state.title}", :cyan)
        end

        @impl true
        def handle_input("q", _state), do: :quit
        def handle_input(input, state), do: {:ok, %{state | title: input}}
      end
  """

  @type state :: term()
  @type opts :: map()

  @doc """
  Initialize screen state from the given options map.

  Called once when the screen is first activated (or re-activated
  after being popped from the stack).
  """
  @callback init(opts()) :: {:ok, state()}

  @doc """
  Render the current screen state into an `Owl.Data.t()` fragment.

  The App will pass this to `Owl.IO.puts/2` or an `Owl.LiveScreen`
  block depending on the display mode.
  """
  @callback render(state()) :: Owl.Data.t()

  @doc """
  Handle a line of user input.

  Return values:
    * `{:ok, state}`         — update state and re-render
    * `{:switch, mod, opts}` — navigate to `mod` with `opts`
    * `:quit`                — shut down the TUI
  """
  @callback handle_input(input :: String.t(), state()) ::
              {:ok, state()} | {:switch, module(), opts()} | :quit

  @doc """
  Optional cleanup callback invoked when the screen is deactivated.

  Default implementation is a no-op.
  """
  @callback cleanup(state()) :: :ok

  @optional_callbacks [cleanup: 1]

  # ── Helpers ──────────────────────────────────────────────────────────────

  @doc """
  Run a screen in a standalone loop (no App GenServer).

  Useful for quick testing or single-screen CLIs. Reads lines from
  `IO.gets/1` until the screen returns `:quit` or encounters EOF.

  ## Options

    * `:prompt` — prompt string shown before each input (default: `"> "`)
  """
  @spec run(module(), opts()) :: :ok
  def run(module, opts \\ %{}) do
    prompt = Map.get(opts, :prompt, "> ")
    opts = Map.delete(opts, :prompt)

    {:ok, state} = module.init(opts)
    do_run(module, state, prompt)
  end

  defp do_run(module, state, prompt) do
    Owl.IO.puts(module.render(state))

    case IO.gets(prompt) do
      :eof ->
        maybe_cleanup(module, state)
        :ok

      {:error, _reason} ->
        maybe_cleanup(module, state)
        :ok

      line ->
        trimmed = String.trim_trailing(line, "\n")

        case module.handle_input(trimmed, state) do
          {:ok, new_state} ->
            do_run(module, new_state, prompt)

          {:switch, next_mod, next_opts} ->
            maybe_cleanup(module, state)
            {:ok, new_state} = next_mod.init(next_opts)
            do_run(next_mod, new_state, prompt)

          :quit ->
            maybe_cleanup(module, state)
            :ok
        end
    end
  end

  defp maybe_cleanup(module, state) do
    if function_exported?(module, :cleanup, 1) do
      module.cleanup(state)
    else
      :ok
    end
  end
end
