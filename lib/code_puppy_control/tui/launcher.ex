defmodule CodePuppyControl.TUI.Launcher do
  @moduledoc """
  Entry point for the Code Puppy TUI.

  Handles environment-variable gating, banner display, and wiring
  the TUI.Supervisor with the correct initial screen.

  ## Gating Convention

  The TUI is **opt-in** via `PUP_TUI=1` (env var convention per
  CONTRIBUTING.md). The legacy `CODE_PUPPY_TUI` is supported as a
  compatibility alias with a deprecation warning. When neither is
  set, the default is the CLI REPL mode.

  ## Usage

      # From application startup or CLI dispatch
      case TUI.Launcher.launch() do
        {:ok, pid} ->  # TUI running
        {:error, :tui_disabled} ->  # Fall through to CLI REPL
      end

      # Explicit start with options
      TUI.Launcher.launch(screen: MyApp.CustomScreen, session_id: "sess-1")

  ## Startup Sequence

  1. Check `PUP_TUI=1` env var
  2. Print the Code Puppy banner
  3. Start `TUI.Supervisor` with the initial screen
  4. Return `{:ok, supervisor_pid}` or `{:error, reason}`
  """

  require Logger

  alias CodePuppyControl.TUI.{Supervisor, Theme}
  alias Owl.{Box, Data}

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Launch the TUI if enabled, otherwise return `{:error, :tui_disabled}`.

  ## Options

    * `:screen` — initial screen module (default: `Screens.Chat`)
    * `:screen_opts` — initial screen options (default: `%{}`)
    * `:session_id` — session ID for Renderer PubSub subscription
    * `:force` — launch even without `PUP_TUI` (for testing)

  ## Returns

    * `{:ok, pid}` — TUI supervisor started
    * `{:error, :tui_disabled}` — env var not set
    * `{:error, reason}` — supervisor failed to start
  """
  @spec launch(keyword()) :: {:ok, pid()} | {:error, :tui_disabled | term()}
  def launch(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force or tui_enabled?() do
      do_launch(opts, force)
    else
      {:error, :tui_disabled}
    end
  end

  @doc """
  Check if the TUI is enabled via the environment variable.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: tui_enabled?()

  @doc """
  Print the Code Puppy TUI banner.

  Displays the puppy branding with Owl-styled output. Safe to call
  even when Owl is not fully initialized (e.g. no TTY).
  """
  @spec print_banner() :: :ok
  def print_banner do
    title = Theme.brand("Code Puppy")

    version =
      try do
        Application.spec(:code_puppy_control, :vsn) |> to_string()
      catch
        _, _ -> "dev"
      end

    version_tag = Data.tag(" v#{version} ", [:white, :black_background])
    subtitle = Data.tag("  Terminal UI Mode", :faint)

    banner =
      Box.new(
        [title, " ", version_tag, subtitle],
        min_width: Theme.min_box_width(),
        border: :bottom,
        border_color: Theme.color(:brand)
      )

    owl_puts(banner)
    owl_puts(Theme.separator())
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_launch(opts, force) do
    screen = Keyword.get(opts, :screen, CodePuppyControl.TUI.Screens.Chat)
    screen_opts = Keyword.get(opts, :screen_opts, %{})
    session_id = Keyword.get(opts, :session_id)

    print_banner()

    sup_opts = [
      screen: screen,
      screen_opts: screen_opts,
      session_id: session_id,
      force: force
    ]

    case Supervisor.start_link(sup_opts) do
      {:ok, pid} ->
        Logger.info("TUI.Launcher: TUI started successfully")
        {:ok, pid}

      {:error, :tui_disabled} = err ->
        Logger.debug("TUI.Launcher: TUI disabled by env var")
        err

      {:error, reason} = err ->
        Logger.error("TUI.Launcher: failed to start TUI: #{inspect(reason)}")
        err
    end
  end

  # Primary env var is PUP_TUI (per project convention).
  # CODE_PUPPY_TUI is a legacy alias — supported with deprecation.
  defp tui_enabled? do
    case System.get_env("PUP_TUI") do
      v when v in ["1", "true"] ->
        true

      _ ->
        # Fallback to legacy CODE_PUPPY_TUI with deprecation warning
        case System.get_env("CODE_PUPPY_TUI") do
          v when v in ["1", "true"] ->
            Logger.warning("TUI.Launcher: CODE_PUPPY_TUI is deprecated, use PUP_TUI instead")
            true

          _ ->
            false
        end
    end
  end

  defp owl_puts(data) do
    try do
      Owl.IO.puts(data)
    catch
      :error, :terminated -> :ok
      :exit, :terminated -> :ok
    end
  end
end
