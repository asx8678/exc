defmodule CodePuppyControl.TUI.Supervisor do
  @moduledoc """
  OTP Supervisor for TUI processes.

  Manages the lifecycle of the TUI App (screen navigation) and the
  streaming Renderer under a single supervisor. This ensures that
  if either process crashes, it is restarted appropriately.

  ## Architecture

      TUI.Supervisor (RestForOne)
      ├── TUI.App        (permanent — screen navigation GenServer)
      └── TUI.Renderer   (transient — streaming event renderer)

  `:rest_for_one` means if the App crashes, the Renderer is also
  restarted (since it depends on the App for screen context). If
  the Renderer crashes, only it is restarted.

  ## Usage

      # Start with default Chat screen
      {:ok, pid} = TUI.Supervisor.start_link()

      # Start with a custom screen
      {:ok, pid} = TUI.Supervisor.start_link(screen: MyApp.HomeScreen)

      # Stop the entire TUI
      TUI.Supervisor.stop()

  ## Environment Gating

  The supervisor is a no-op unless `PUP_TUI=1` is set (per project
  env var convention). The legacy `CODE_PUPPY_TUI` is supported as a
  compatibility alias with deprecation. When neither is set,
  `start_link/1` returns `{:error, :tui_disabled}`.

  This is the **only** entry point for starting the TUI. All other
  modules (App, Renderer) should be started via this supervisor, not
  directly.
  """

  use Supervisor

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Start the TUI supervisor.

  ## Options

    * `:screen` — initial screen module (default: `Screens.Chat`)
    * `:screen_opts` — options for the initial screen (default: `%{}`)
    * `:session_id` — session ID for the Renderer's PubSub subscription
    * `:name` — supervisor name registration (default: `__MODULE__`)
    * `:force` — start even without `PUP_TUI` env var (for testing)

  Returns `{:error, :tui_disabled}` when `PUP_TUI` is not set
  and `:force` is not `true`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, :tui_disabled}
  def start_link(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force or tui_enabled?() do
      name = Keyword.get(opts, :name, __MODULE__)
      Supervisor.start_link(__MODULE__, opts, name: name)
    else
      Logger.debug("TUI.Supervisor: PUP_TUI not set, skipping TUI startup")
      {:error, :tui_disabled}
    end
  end

  @doc """
  Gracefully stop the TUI supervisor and all its children.
  """
  @spec stop(keyword()) :: :ok
  def stop(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Process.whereis(name) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end
  end

  @doc """
  Check whether the TUI is currently enabled and running.
  """
  @spec running?(keyword()) :: boolean()
  def running?(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # ── Supervisor Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    screen = Keyword.get(opts, :screen, CodePuppyControl.TUI.Screens.Chat)
    screen_opts = Keyword.get(opts, :screen_opts, %{})
    session_id = Keyword.get(opts, :session_id)

    children = [
      # App — screen navigation GenServer (permanent restart)
      %{
        id: CodePuppyControl.TUI.App,
        start:
          {CodePuppyControl.TUI.App, :start_link, [[screen: screen, screen_opts: screen_opts]]},
        restart: :permanent,
        type: :worker
      },
      # Renderer — streaming LLM output (transient restart)
      # Only start with session_id if provided
      renderer_spec(session_id)
    ]

    # Use rest_for_one: if App crashes, restart Renderer too
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ── Private ────────────────────────────────────────────────────────────

  # When no session_id is provided, start the Renderer subscribed to
  # EventBus.global_topic/0 so it still receives system-wide events
  # (status, agent_run_completed, etc). This avoids a dead renderer
  # that is started but subscribed to nothing.
  # Decision: option (b) — subscribe to global topic. Option (a) skip
  # Renderer entirely was rejected because the Renderer also handles
  # UI concerns like finalization; option (c) require explicit topic
  # was rejected as too rigid for the default case.
  defp renderer_spec(nil) do
    %{
      id: CodePuppyControl.TUI.Renderer,
      start: {CodePuppyControl.TUI.Renderer, :start_link, [[subscribe_global: true]]},
      restart: :transient,
      type: :worker
    }
  end

  defp renderer_spec(session_id) do
    %{
      id: CodePuppyControl.TUI.Renderer,
      start: {CodePuppyControl.TUI.Renderer, :start_link, [[session_id: session_id]]},
      restart: :transient,
      type: :worker
    }
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
            Logger.warning("TUI.Supervisor: CODE_PUPPY_TUI is deprecated, use PUP_TUI instead")
            true

          _ ->
            false
        end
    end
  end
end
