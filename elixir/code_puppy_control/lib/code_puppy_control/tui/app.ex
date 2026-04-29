defmodule CodePuppyControl.TUI.App do
  @moduledoc """
  TUI application managing screen navigation.

  The App GenServer owns a stack of screens and drives the render/input
  cycle. Navigation uses a **stack model**:

    * `switch_screen/2` — replace the current screen (like navigating
      to a new page — the previous screen is discarded)
    * `push_screen/2` — push a screen on top (for modals / overlays)
    * `pop_screen/0` — return to the previous screen on the stack

  ## Architecture

  The App delegates rendering and input handling to the active screen
  module (see `CodePuppyControl.TUI.Screen` behaviour). It manages
  the screen state internally so that screen modules stay pure.

  When Owl.LiveScreen is available, the App renders into a live block
  for flicker-free updates. Otherwise it falls back to `Owl.IO.puts/2`.

  ## Usage

      # Start the app with an initial screen
      {:ok, pid} = App.start_link(screen: MyApp.HomeScreen)

      # Navigate
      App.switch_screen(MyApp.SettingsScreen, %{section: :models})
      App.push_screen(MyApp.HelpScreen, %{})
      App.pop_screen()
      App.current_screen()  #=> MyApp.SettingsScreen

  ## State

      %{
        screen_stack: [{module, opts, state}, ...],
        live_block_id: atom() | nil
      }

  The head of `screen_stack` is the active screen. The rest are
  suspended screens waiting for `pop_screen/0`.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.TUI.Screen

  # ── State ────────────────────────────────────────────────────────────────

  defstruct screen_stack: [], live_block_id: nil

  @type screen_entry :: {module(), Screen.opts(), Screen.state()}
  @type t :: %__MODULE__{screen_stack: [screen_entry()], live_block_id: atom() | nil}

  # ── Client API ───────────────────────────────────────────────────────────

  @doc """
  Start the App GenServer.

  ## Options

    * `:screen` (required) — initial screen module
    * `:screen_opts` — options passed to `screen.init/1` (default: `%{}`)
    * `:name` — GenServer name registration (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Replace the current screen with a new one.

  The previous screen is **discarded** (its `cleanup/1` is called).
  Use `push_screen/2` if you want to return later.
  """
  @spec switch_screen(module(), Screen.opts(), GenServer.server()) :: :ok | {:error, term()}
  def switch_screen(module, opts \\ %{}, server \\ __MODULE__)

  def switch_screen(module, opts, server) do
    GenServer.call(server, {:switch_screen, module, opts})
  end

  @doc """
  Push a new screen on top of the stack (modal / overlay).

  The current screen is suspended and will be restored by `pop_screen/0`.
  """
  @spec push_screen(module(), Screen.opts(), GenServer.server()) :: :ok | {:error, term()}
  def push_screen(module, opts \\ %{}, server \\ __MODULE__)

  def push_screen(module, opts, server) do
    GenServer.call(server, {:push_screen, module, opts})
  end

  @doc """
  Pop the current screen and return to the previous one.

  Does nothing if there is only one screen on the stack.
  """
  @spec pop_screen(GenServer.server()) :: :ok
  def pop_screen(server \\ __MODULE__) do
    GenServer.call(server, :pop_screen)
  end

  @doc """
  Send a line of input to the active screen.

  The App delegates to `screen.handle_input/2` and acts on the result:
    * `{:ok, state}` — update state and re-render
    * `{:switch, mod, opts}` — navigate to new screen
    * `:quit` — stop the GenServer
  """
  @spec send_input(String.t(), GenServer.server()) :: :ok
  def send_input(input, server \\ __MODULE__) do
    GenServer.cast(server, {:input, input})
  end

  @doc """
  Return the module of the currently active screen.
  """
  @spec current_screen(GenServer.server()) :: module() | nil
  def current_screen(server \\ __MODULE__) do
    GenServer.call(server, :current_screen)
  end

  @doc """
  Return the full screen stack (for diagnostics).
  """
  @spec stack(GenServer.server()) :: [screen_entry()]
  def stack(server \\ __MODULE__) do
    GenServer.call(server, :stack)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    screen_mod = Keyword.fetch!(opts, :screen)
    screen_opts = Keyword.get(opts, :screen_opts, %{})

    case safe_init(screen_mod, screen_opts) do
      {:ok, state} ->
        entry = {screen_mod, screen_opts, state}
        live_block_id = maybe_add_live_block()
        render_active(%__MODULE__{screen_stack: [entry], live_block_id: live_block_id})
        {:ok, %__MODULE__{screen_stack: [entry], live_block_id: live_block_id}}

      {:error, reason} ->
        Logger.error("TUI.App: screen init failed for #{inspect(screen_mod)}: #{inspect(reason)}")
        {:stop, {:screen_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:switch_screen, mod, opts}, _from, %{screen_stack: stack} = s) do
    # Cleanup current screen, preserve the rest of the stack
    {rest, cur_mod, cur_state} =
      case stack do
        [{cm, _, cs} | r] -> {r, cm, cs}
        [] -> {[], nil, nil}
      end

    if cur_mod, do: maybe_cleanup(cur_mod, cur_state)

    case safe_init(mod, opts) do
      {:ok, new_state} ->
        new_stack = [{mod, opts, new_state} | rest]
        new_s = %{s | screen_stack: new_stack}
        render_active(new_s)
        {:reply, :ok, new_s}

      {:error, reason} ->
        Logger.error("TUI.App: switch_screen init failed for #{inspect(mod)}: #{inspect(reason)}")
        render_error("Screen init failed: #{inspect(reason)}")
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:push_screen, mod, opts}, _from, %{screen_stack: stack} = s) do
    case safe_init(mod, opts) do
      {:ok, new_state} ->
        new_stack = [{mod, opts, new_state} | stack]
        new_s = %{s | screen_stack: new_stack}
        render_active(new_s)
        {:reply, :ok, new_s}

      {:error, reason} ->
        Logger.error("TUI.App: push_screen init failed for #{inspect(mod)}: #{inspect(reason)}")
        render_error("Screen init failed: #{inspect(reason)}")
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call(:pop_screen, _from, %{screen_stack: stack} = s) do
    case stack do
      [{mod, _, state} | rest] when rest != [] ->
        maybe_cleanup(mod, state)
        new_s = %{s | screen_stack: rest}
        render_active(new_s)
        {:reply, :ok, new_s}

      _ ->
        # Single screen or empty — ignore
        {:reply, :ok, s}
    end
  end

  @impl true
  def handle_call(:current_screen, _from, %{screen_stack: [{mod, _, _} | _]} = s) do
    {:reply, mod, s}
  end

  @impl true
  def handle_call(:current_screen, _from, s) do
    {:reply, nil, s}
  end

  @impl true
  def handle_call(:stack, _from, s) do
    {:reply, s.screen_stack, s}
  end

  @impl true
  def handle_cast({:input, input}, %{screen_stack: [{mod, opts, state} | rest]} = s) do
    case safe_handle_input(mod, input, state) do
      {:ok, new_state} ->
        new_s = %{s | screen_stack: [{mod, opts, new_state} | rest]}
        render_active(new_s)
        {:noreply, new_s}

      {:switch, next_mod, next_opts} ->
        maybe_cleanup(mod, state)

        case safe_init(next_mod, next_opts) do
          {:ok, next_state} ->
            new_stack = [{next_mod, next_opts, next_state} | rest]
            new_s = %{s | screen_stack: new_stack}
            render_active(new_s)
            {:noreply, new_s}

          {:error, reason} ->
            Logger.error("TUI.App: input switch init failed: #{inspect(reason)}")
            render_error("Screen init failed: #{inspect(reason)}")
            {:noreply, s}
        end

      :quit ->
        maybe_cleanup(mod, state)
        {:stop, :normal, %{s | screen_stack: []}}

      {:error, reason} ->
        Logger.error("TUI.App: handle_input error in #{inspect(mod)}: #{inspect(reason)}")
        render_error("Input error: #{inspect(reason)}")
        {:noreply, s}
    end
  end

  @impl true
  def handle_cast({:input, _input}, s) do
    # No active screen — ignore
    {:noreply, s}
  end

  @impl true
  def terminate(_reason, %{screen_stack: stack}) do
    Enum.each(stack, fn {mod, _, state} -> maybe_cleanup(mod, state) end)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp render_active(%{screen_stack: [{mod, _, state} | _], live_block_id: block_id}) do
    data = safe_render(mod, state)

    if block_id && function_exported?(Owl.LiveScreen, :update, 2) do
      try do
        Owl.LiveScreen.update(block_id, data)
      catch
        kind, reason ->
          Logger.error("TUI.App: Owl.LiveScreen.update failed: #{kind} #{inspect(reason)}")
          :ok
      end
    else
      owl_puts(data)
    end
  end

  defp render_active(_), do: :ok

  defp render_error(message) do
    owl_puts(Owl.Data.tag(" [TUI Error] #{message}", :red))
  end

  defp maybe_add_live_block do
    if tty?() and function_exported?(Owl.LiveScreen, :add_block, 2) do
      try do
        Owl.LiveScreen.add_block(:tui_app, render: &Function.identity/1)
        :tui_app
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  defp maybe_cleanup(mod, state) do
    if function_exported?(mod, :cleanup, 1) do
      try do
        mod.cleanup(state)
      catch
        kind, reason ->
          Logger.error("TUI.App: cleanup failed for #{inspect(mod)}: #{kind} #{inspect(reason)}")
          :ok
      end
    end

    :ok
  end

  # ── Safe Dispatchers ────────────────────────────────────────────────────
  #
  # Screen lifecycle callbacks may fail (bad init, render crash, etc).
  # These wrappers catch failures and degrade gracefully instead of
  # crashing the entire TUI GenServer.

  defp safe_init(mod, opts) do
    mod.init(opts)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_render(mod, state) do
    try do
      mod.render(state)
    catch
      kind, reason ->
        Logger.error("TUI.App: render failed for #{inspect(mod)}: #{kind} #{inspect(reason)}")
        Owl.Data.tag(" [Render Error]", :red)
    end
  end

  defp safe_handle_input(mod, input, state) do
    mod.handle_input(input, state)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp owl_puts(data) do
    try do
      Owl.IO.puts(data)
    catch
      :error, :terminated ->
        :ok

      :exit, :terminated ->
        :ok

      kind, reason ->
        Logger.error("TUI.App: Owl.IO.puts failed: #{kind} #{inspect(reason)}")
        :ok
    end
  end

  # Heuristic: detect if we're on a real terminal
  defp tty? do
    if function_exported?(:file, :isatty, 1) do
      apply(:file, :isatty, [:stdio])
    else
      false
    end
  end
end
