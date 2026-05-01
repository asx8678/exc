defmodule CodePuppyControl.Application do
  @moduledoc """
  OTP Application for CodePuppy Control Plane.

  Supervision tree:
  1. CodePuppyControl.HttpClient - Finch HTTP connection pool
  2. CodePuppyControl.Parsing.ParserRegistry - Language parser registry (Agent-backed)
  3. CodePuppyControl.Repo - SQLite database for state persistence
  4. Phoenix.PubSub - Event distribution
  5. CodePuppyControl.EventStore - ETS-based event history for replay
  5a. CodePuppyControl.SessionStorage.Store - ETS session cache + PubSub + terminal recovery (code_puppy-ctj.1)
  5b. CodePuppyControl.SessionStorage.AutosaveTracker - Autosave debounce/dedup
  6. CodePuppyControl.RuntimeState - Global runtime state (autosave ID, session model)
  7. CodePuppyControl.Callbacks.Registry - ETS-backed callback storage (must start before PolicyEngine)
  7a. CodePuppyControl.HookEngine - Configurable hook script engine (must start after Callbacks.Registry)
  8. CodePuppyControl.PolicyEngine - Priority-based policy rule engine
  9. CodePuppyControl.AgentModelPinning - Agent-to-model pin configuration (ETS-backed)
  9b. CodePuppyControl.ModelFactory.ProviderRegistry - Provider type -> module mapping (Agent-backed)
  9a. CodePuppyControl.ModelRegistry - Model configuration registry (ETS-backed)
  9b. CodePuppyControl.ModelAvailability - Model health circuit breaker (ETS-backed)
  9c. CodePuppyControl.ModelPacks - Role-based model packs
  9d. CodePuppyControl.Tools.AgentCatalogue - Agent catalogue with descriptions
  9d2. CodePuppyControl.Tools.AgentManager - Session mgmt, JSON discovery, clones
  9e. CodePuppyControl.Tools.UniversalConstructor.Registry - UC tool discovery
  10. CodePuppyControl.RoundRobinModel - Round-robin model rotation (ETS-backed)
  11a. CodePuppyControl.ModelsDevParser.Registry - Models.dev API registry
  12. CodePuppyControl.Run.Registry - Process registry for run tracking
  13. CodePuppyControl.Tool.Registry - ETS-backed tool registry
  14. CodePuppyControl.Run.Supervisor - DynamicSupervisor for run processes
  15. CodePuppyControl.PythonWorker.Supervisor - DynamicSupervisor for Python workers
  16. CodePuppyControl.MCP.Registry - Process registry for MCP servers
  17. CodePuppyControl.MCP.Supervisor - DynamicSupervisor for MCP servers
  18. CodePuppyControl.Concurrency.Supervisor - Concurrency limiter (ETS-backed)
  18b. CodePuppyControl.Plugins.PackParallelism.Supervisor - Pack run semaphore (replaces Python _async_active HACK)
  19. CodePuppyControl.TokenLedger - Token usage accounting
  19b. CodePuppyControl.Config.Writer - Atomic puppy.cfg write-back
  20. CodePuppyControl.RequestTracker - Tracks JSON-RPC request/response correlation
  21. CodePuppyControl.Tools.CommandRunner.ProcessManager - Shell process tracking
  22. CodePuppyControl.PtyManager - PTY session manager for interactive terminals
  23. Oban - Job processing engine with SQLite Lite engine (queues: default, scheduled, workflows)
  23. CodePuppyControl.Scheduler.CronScheduler - Periodic scheduler for cron tasks
  24. CodePuppyControlWeb.Endpoint - HTTP API endpoint
  """

  use Application

  # Compile-time env check — safe for releases (Mix.env() is evaluated at
  # compile time when used in module attributes). Runtime Mix.env() calls
  # are forbidden in application startup because Mix may not be available
  # in a Burrito release. (code_puppy-5xd.6)
  @env Mix.env()
  @test_supervisor_opts if @env == :test, do: [max_restarts: 1000, max_seconds: 60], else: []
  @exclude_cron_scheduler @env == :test

  @impl true
  def start(_type, _args) do
    # Fast-path for --help / --version under Burrito.
    # config/runtime.exs skips loading prod config in this case, so we must
    # also skip starting the full supervision tree (Repo/Endpoint would crash
    # without their config). We start an empty supervisor to satisfy the OTP
    # Application contract, spawn the CLI dispatch, then System.halt(0).
    if burrito_cli_mode?() and
         CodePuppyControl.Config.cli_help_or_version_flag?(burrito_argv()) do
      spawn_burrito_cli()
      Supervisor.start_link([], strategy: :one_for_one, name: CodePuppyControl.Supervisor)
    else
      start_normal()
    end
  end

  defp start_normal do
    children = [
      # HTTP client connection pool (Finch)
      CodePuppyControl.HttpClient.child_spec(),
      # Parser registry (must start before any parsing operations)
      CodePuppyControl.Parsing.ParserRegistry,
      # Register built-in parsers (must come after ParserRegistry)
      CodePuppyControl.Parsing.Parsers,
      CodePuppyControl.Repo,
      {Phoenix.PubSub, name: CodePuppyControl.PubSub},
      CodePuppyControl.EventStore,
      # Session storage ETS cache + PubSub (must start before AutosaveTracker)
      # (code_puppy-ctj.1) Provides crash-survivable write-through caching
      # and terminal session recovery tracking.
      CodePuppyControl.SessionStorage.Store,
      # Autosave debounce/dedup tracker for session storage
      CodePuppyControl.SessionStorage.AutosaveTracker,
      CodePuppyControl.RuntimeState,
      # Workflow state tracking for /flags command
      # TODO(code-puppy-ctj.3): Migrated from WorkflowState to Workflow.State
      {CodePuppyControl.Workflow.State, name: CodePuppyControl.Workflow.State},
      # Callback registry (ETS-backed GenServer) — must start before
      # any component triggers or registers callbacks (e.g. plugin loader,
      # security checks, slash commands).
      CodePuppyControl.Callbacks.Registry,
      # HookEngine (GenServer) for configurable hook scripts.
      # Must start AFTER Callbacks.Registry so that CallbackAdapter.register/1
      # can safely register pre_tool_call / post_tool_call callbacks.
      {CodePuppyControl.HookEngine, name: CodePuppyControl.HookEngine},
      CodePuppyControl.PolicyEngine,
      CodePuppyControl.AgentModelPinning,
      # Provider registry (Agent-backed) for provider type → module mapping
      CodePuppyControl.ModelFactory.ProviderRegistry,
      CodePuppyControl.ModelRegistry,
      CodePuppyControl.ModelAvailability,
      CodePuppyControl.ModelPacks,
      CodePuppyControl.Tools.AgentCatalogue,
      # Agent manager — session tracking, JSON discovery, clone management
      CodePuppyControl.Tools.AgentManager,
      # UC tool registry (GenServer) for Universal Constructor tool discovery
      CodePuppyControl.Tools.UniversalConstructor.Registry,
      CodePuppyControl.RoundRobinModel,
      CodePuppyControl.ModelsDevParser.Registry,
      CodePuppyControl.Run.Registry,
      # Per-{session,agent} message history state
      CodePuppyControl.Agent.State.Registry,
      # Tool registry (ETS-backed) for agent tool dispatch
      CodePuppyControl.Tool.Registry,
      # Slash command registry (ETS-backed) for REPL command dispatch
      CodePuppyControl.CLI.SlashCommands.Registry,
      # Serialises /add_model persistence to prevent lost-update races
      CodePuppyControl.CLI.SlashCommands.Commands.AddModelPersistence.LockKeeper,
      # Staged changes sandbox for diff-preview system
      CodePuppyControl.Tools.StagedChanges,
      {CodePuppyControl.Run.Supervisor, []},
      CodePuppyControl.Agent.State.Supervisor,
      CodePuppyControl.PythonWorker.Supervisor,
      # MCP Server supervision
      {Registry, keys: :unique, name: CodePuppyControl.MCP.Registry},
      CodePuppyControl.MCP.Supervisor,
      # MCP Client supervision
      {Registry, keys: :unique, name: CodePuppyControl.MCP.ClientRegistry},
      CodePuppyControl.MCP.ToolIndex,
      CodePuppyControl.MCP.ClientSupervisor,
      # Concurrency limiter (ETS-backed semaphores for file_ops, api_calls, tool_calls)
      CodePuppyControl.Concurrency.Supervisor,
      # Pack parallelism semaphore GenServer (replaces Python _async_active HACK)
      CodePuppyControl.Plugins.PackParallelism.Supervisor,
      # Adaptive rate limiter with circuit breaker
      CodePuppyControl.RateLimiter.Supervisor,
      # Token ledger for per-run/session token accounting
      CodePuppyControl.TokenLedger,
      # Atomic write-back for puppy.cfg
      # Must start before any /mode or preset command can be dispatched,
      # since Presets.apply_preset/1 calls Writer.set_values/1 which
      # requires the GenServer to be alive.
      CodePuppyControl.Config.Writer,
      CodePuppyControl.RequestTracker,
      # Renderer registry — avoids String.to_atom for per-session renderers
      {Registry, keys: :unique, name: CodePuppyControl.REPL.RendererRegistry},

      # Shell command runner process tracking
      CodePuppyControl.Tools.CommandRunner.ProcessManager,
      # PTY session manager for interactive terminals
      CodePuppyControl.PtyManager,
      # Auth rate limiter ETS table owner
      # Must be a long-lived GenServer, not a Task, so the ETS table survives.
      CodePuppyControlWeb.Plugs.RateLimiterServer,
      # Oban job processing with SQLite engine
      {Oban, Application.fetch_env!(:code_puppy_control, Oban)}
      # Periodic scheduler for cron tasks — excluded in test to avoid
      # Ecto-sandbox contention. CronScheduler tests start
      # their own supervised instance instead. (code_puppy-5xd.6)
      | cron_scheduler_child() ++ [CodePuppyControlWeb.Endpoint]
    ]

    # Relax restart intensity in test to tolerate repeated kills in OTP lifecycle
    # tests. Production retains OTP defaults (3 restarts / 5 seconds).
    opts = [strategy: :one_for_one, name: CodePuppyControl.Supervisor] ++ @test_supervisor_opts

    result = Supervisor.start_link(children, opts)

    # Register built-in slash commands after supervision tree is up.
    # Must happen AFTER the Registry GenServer is started.
    # Failures are logged but do not crash the application.
    with {:ok, _pid} <- result do
      try do
        CodePuppyControl.CLI.SlashCommands.Registry.register_builtin_commands()
      rescue
        e ->
          require Logger
          Logger.warning("Failed to register built-in slash commands: #{inspect(e)}")
      end

      # Wire workflow-state callback handlers AFTER the Callbacks.Registry
      # is started. This ensures flags like :did_execute_shell and
      # :did_generate_code are set automatically based on tool calls and
      # agent lifecycle events. Failures are logged but non-fatal.
      try do
        CodePuppyControl.Workflow.State.register_callback_handlers()
      rescue
        e ->
          require Logger
          Logger.warning("Failed to register workflow-state callbacks: #{inspect(e)}")
      end

      # Wire HookEngine CallbackAdapter AFTER Callbacks.Registry and
      # HookEngine are started.  The adapter registers stable named function
      # captures as :pre_tool_call / :post_tool_call callbacks, routing
      # tool events through the configured hook engine.
      # Idempotent — safe to call on supervision restart.
      try do
        CodePuppyControl.HookEngine.CallbackAdapter.register()
      rescue
        e ->
          require Logger
          Logger.warning("Failed to register HookEngine callback adapter: #{inspect(e)}")
      end
    end

    # When running inside a Burrito-wrapped binary, dispatch the CLI
    # after the supervision tree is up, then halt the VM.
    if burrito_cli_mode?() do
      spawn_burrito_cli()
    end

    result
  end

  defp spawn_burrito_cli do
    args = burrito_argv()

    spawn(fn ->
      try do
        CodePuppyControl.CLI.main(args)
        System.halt(0)
      rescue
        e ->
          IO.puts(
            :stderr,
            "Burrito CLI crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          System.halt(1)
      catch
        :exit, {:shutdown, code} when is_integer(code) ->
          System.halt(code)

        kind, reason ->
          IO.puts(:stderr, "Burrito CLI aborted (#{kind}): #{inspect(reason)}")
          System.halt(1)
      end
    end)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CodePuppyControlWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ── Burrito CLI dispatch helpers ────────────────────────────────

  # CronScheduler is excluded from the supervision tree in test env to
  # prevent Ecto-sandbox contention. Even with pool_size: 2, the global
  # CronScheduler would hold one connection indefinitely, reducing
  # available connections for test processes. CronScheduler unit tests
  # start their own isolated instance via start_supervised/1 instead.
  # Uses compile-time @exclude_cron_scheduler attribute (not runtime
  # Mix.env()) for release safety. (code_puppy-5xd.6)
  defp cron_scheduler_child do
    if @exclude_cron_scheduler, do: [], else: [{CodePuppyControl.Scheduler.CronScheduler, []}]
  end

  # Detect Burrito runtime context. Burrito sets `__BURRITO` at launch.
  defp burrito_cli_mode? do
    System.get_env("__BURRITO") != nil
  end

  # Read CLI arguments passed through the Burrito wrapper.
  #
  # We use `:init.get_plain_arguments/0` directly instead of
  # `Burrito.Util.Args.argv/0` because the :burrito dependency is
  # declared `runtime: false` — it's only needed at build time for
  # `mix release`. Calling Burrito modules at runtime would raise
  # UndefinedFunctionError.
  #
  # This mirrors exactly what `Burrito.Util.Args.argv/0` does internally
  # when running inside a Burrito binary (it delegates to
  # `:init.get_plain_arguments/0`). Outside Burrito, `System.argv/0` is
  # the correct source, so we fall back to that.
  #
  # Verified in (macOS arm64, Burrito 1.3, Zig 0.15.2, Elixir 1.19.5
  # / OTP 28): option flags, positional args, short/long forms, string
  # values with spaces, and error-exit codes all round-trip correctly
  # through the Burrito wrapper via :init.get_plain_arguments/0.
  # Cross-platform verification (linux_x86_64, linux_arm64, windows_x86_64)
  # is deferred to the CI matrix build.
  defp burrito_argv do
    if burrito_cli_mode?() do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end
end
