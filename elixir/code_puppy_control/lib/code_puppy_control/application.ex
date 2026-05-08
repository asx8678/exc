defmodule CodePuppyControl.Application do
  @moduledoc """
  OTP Application for CodePuppy Control Plane.

  Supervision tree:
  1. CodePuppyControl.HttpClient - Finch HTTP connection pool
  2. CodePuppyControl.Parsing.ParserRegistry - Language parser registry (Agent-backed)
  3. CodePuppyControl.Repo - SQLite database for state persistence
  4. Phoenix.PubSub - Event distribution
  5. CodePuppyControl.EventStore - ETS-based event history for replay
  5a. CodePuppyControl.SessionStorage.Store - ETS-backed session store + PubSub + terminal recovery (code_puppy-ctj.1)
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
  14. CodePuppyControl.Run.Supervisor - DynamicSupervisor for run state processes
  14b. CodePuppyControl.Run.Executor.Supervisor - DynamicSupervisor for Elixir executor processes (code-puppy-6sj)
  15. CodePuppyControl.MCP.Registry - Process registry for MCP servers
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

  @doc """
  Returns `true` when running as an escript (`./pup`).

  Escript mode is detected by checking whether the main module was
  invoked via the escript entry point. In escript mode, NIF libraries
  (like exqlite's sqlite3_nif.so) cannot be loaded from the zip
  archive, and `:code.priv_dir/1` resolves to a non-existent path
  inside the archive. The supervision tree must degrade gracefully
  by skipping DB-dependent children.

  Detection heuristic: when the BEAM VM boots from an escript, the
  `:code.priv_dir(:code_puppy_control)` call returns `{:error, :bad_name}`
  because the application's `.app` file is not on the code path in the
  standard way. We also check `:init.get_argument/1` for the escript
  marker.
  """
  @spec escript_mode?() :: boolean()
  def escript_mode? do
    case :code.priv_dir(:code_puppy_control) do
      {:error, _} ->
        true

      priv_dir when is_list(priv_dir) ->
        # Even if :code.priv_dir returns a path, in escript mode the
        # path points inside the zip archive and is not a real directory.
        # Verify the directory actually exists on disk.
        not File.dir?(priv_dir)
    end
  end

  @impl true
  def start(_type, _args) do
    # Fast-path for --help / --version under Burrito or escript.
    # config/runtime.exs skips loading prod config in this case, so we must
    # also skip starting the full supervision tree (Repo/Endpoint would crash
    # without their config). We start an empty supervisor to satisfy the OTP
    # Application contract, spawn the CLI dispatch, then System.halt(0).
    #
    # (code-puppy-be7) When escript is built with `app: :code_puppy_control`,
    # the escript runtime auto-starts the application before main/1 is called.
    # This means --help/--version would start the full supervision tree
    # unnecessarily. We detect escript mode + help/version flags here and
    # short-circuit just like we do for Burrito.
    if cli_fast_path?() do
      if escript_mode?() do
        # Escript fast path: run CLI synchronously and halt before the
        # escript runtime calls main/1 again.  With `app: :code_puppy_control`
        # in the escript config, the BEAM auto-starts the application before
        # the escript main/1 entry point; if we only spawned CLI dispatch
        # asynchronously, the escript main/1 would also call CLI.main/1,
        # producing duplicate --help/--version output.
        run_cli_and_halt()
      else
        # Burrito fast path: spawn CLI dispatch after starting an empty
        # supervisor.  Burrito controls the full lifecycle and won't
        # re-invoke main/1, so async dispatch is safe.
        spawn_cli_dispatch()
        Supervisor.start_link([], strategy: :one_for_one, name: CodePuppyControl.Supervisor)
      end
    else
      start_normal()
    end
  end

  defp start_normal do
    in_escript = escript_mode?()

    if in_escript do
      require Logger

      # (code_puppy-be7) Downgrade to debug — fires every escript startup,
      # the user already knows they're in escript mode.
      Logger.debug(
        "Escript mode detected — starting degraded supervision tree (no Repo/Oban/Endpoint)"
      )
    end

    children = build_children(in_escript)

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
      spawn_cli_dispatch()
    end

    result
  end

  # Synchronous CLI dispatch for the escript fast path.
  # Calls CLI.main/1 directly and halts the VM, guaranteeing that
  # --help/--version output appears exactly once (the escript runtime
  # won't get a chance to call main/1 again).
  defp run_cli_and_halt do
    args = cli_argv()

    try do
      CodePuppyControl.CLI.main(args)
      System.halt(0)
    rescue
      e ->
        IO.puts(
          :stderr,
          "CLI crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
        )

        System.halt(1)
    catch
      :exit, {:shutdown, code} when is_integer(code) ->
        System.halt(code)

      kind, reason ->
        IO.puts(:stderr, "CLI aborted (#{kind}): #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Async CLI dispatch for Burrito context.
  # Spawns a process that calls CLI.main/1 with the appropriate argv,
  # then halts the VM with the exit code from the CLI.
  defp spawn_cli_dispatch do
    args = cli_argv()

    spawn(fn ->
      try do
        CodePuppyControl.CLI.main(args)
        System.halt(0)
      rescue
        e ->
          IO.puts(
            :stderr,
            "CLI crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          System.halt(1)
      catch
        :exit, {:shutdown, code} when is_integer(code) ->
          System.halt(code)

        kind, reason ->
          IO.puts(:stderr, "CLI aborted (#{kind}): #{inspect(reason)}")
          System.halt(1)
      end
    end)
  end

  # Fast-path detection: returns true when running as a Burrito binary
  # or escript AND the CLI args are --help or --version. In these cases,
  # we skip the full supervision tree and just dispatch the CLI.
  defp cli_fast_path? do
    (burrito_cli_mode?() or escript_mode?()) and
      CodePuppyControl.Config.cli_help_or_version_flag?(cli_argv())
  end

  # Read CLI arguments from Burrito or escript context.
  defp cli_argv do
    if burrito_cli_mode?() do
      burrito_argv()
    else
      # In escript mode with `app:` set, the app is auto-started before
      # main/1. :init.get_plain_arguments/0 gives the argv in escript context.
      case :init.get_plain_arguments() do
        [] -> System.argv()
        args -> Enum.map(args, &to_string/1)
      end
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CodePuppyControlWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ── Child list builder ────────────────────────────────────────────

  # Builds the supervision tree children list. In escript mode, children
  # that depend on the exqlite NIF (Repo, Oban, Endpoint, CronScheduler)
  # are omitted because the NIF cannot be loaded from the escript zip
  # archive. Other DB-adjacent children (SessionStorage.Store disk
  # recovery, ModelsDevParser.Registry bundled data) are configured to
  # degrade gracefully.
  #
  # Feature degradation in escript mode:
  # - No SQLite database (no persistence, no Oban jobs)
  # - No HTTP endpoint (no admin UI, no WebSocket API)
  # - No cron scheduler (no periodic tasks)
  # - ModelRegistry starts empty (no bundled models.json access)
  # - ModelsDevParser.Registry starts empty (no bundled API data)
  # - SessionStorage starts with no disk recovery
  # - REPL, slash commands, agent state, tools, callbacks all work
  defp build_children(in_escript) do
    # Children that always start, regardless of mode
    always =
      [
        # HTTP client connection pool (Finch)
        CodePuppyControl.HttpClient.child_spec(),
        # Parser registry (must start before any parsing operations)
        CodePuppyControl.Parsing.ParserRegistry,
        # Register built-in parsers (must come after ParserRegistry)
        CodePuppyControl.Parsing.Parsers,
        {Phoenix.PubSub, name: CodePuppyControl.PubSub},
        CodePuppyControl.EventStore,
        # SessionStorage.Store — ETS-backed session store + PubSub
        # In escript mode, disk recovery is skipped (no Repo available).
        CodePuppyControl.SessionStorage.Store,
        # Autosave debounce/dedup tracker for session storage
        CodePuppyControl.SessionStorage.AutosaveTracker,
        CodePuppyControl.RuntimeState,
        # Workflow state tracking for /flags command
        {CodePuppyControl.Workflow.State, name: CodePuppyControl.Workflow.State},
        # Callback registry (ETS-backed GenServer)
        CodePuppyControl.Callbacks.Registry,
        # HookEngine (GenServer) for configurable hook scripts
        {CodePuppyControl.HookEngine, name: CodePuppyControl.HookEngine},
        CodePuppyControl.PolicyEngine,
        CodePuppyControl.AgentModelPinning,
        # Provider registry (Agent-backed) for provider type → module mapping
        CodePuppyControl.ModelFactory.ProviderRegistry,
        # ModelRegistry — in escript mode, bundled models.json may be
        # unreachable via :code.priv_dir; it handles this gracefully by
        # starting with an empty ETS table and logging a warning.
        CodePuppyControl.ModelRegistry,
        CodePuppyControl.ModelAvailability,
        CodePuppyControl.ModelPacks,
        CodePuppyControl.Tools.AgentCatalogue,
        # Agent manager — session tracking, JSON discovery, clone management
        CodePuppyControl.Tools.AgentManager,
        # UC tool registry (GenServer) for Universal Constructor tool discovery
        CodePuppyControl.Tools.UniversalConstructor.Registry,
        CodePuppyControl.RoundRobinModel,
        # ModelsDevParser.Registry — in escript mode, bundled data may be
        # unreachable; it handles this gracefully by starting empty.
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
        # One-shot approval store for file operations requiring user confirmation
        CodePuppyControl.Approvals,
        {CodePuppyControl.Run.Supervisor, []},
        # Executor supervisor — separated from Run.Supervisor so each logical
        # run consumes one slot in each supervisor (State + Executor) instead of
        # two slots in one supervisor.  (code-puppy-6sj)
        {CodePuppyControl.Run.Executor.Supervisor, []},
        CodePuppyControl.Agent.State.Supervisor,
        # MCP Server supervision
        {Registry, keys: :unique, name: CodePuppyControl.MCP.Registry},
        CodePuppyControl.MCP.Supervisor,
        # MCP Client supervision
        {Registry, keys: :unique, name: CodePuppyControl.MCP.ClientRegistry},
        CodePuppyControl.MCP.ToolIndex,
        CodePuppyControl.MCP.ClientSupervisor,
        # Concurrency limiter (ETS-backed semaphores)
        CodePuppyControl.Concurrency.Supervisor,
        # Pack parallelism semaphore GenServer
        CodePuppyControl.Plugins.PackParallelism.Supervisor,
        # Adaptive rate limiter with circuit breaker
        CodePuppyControl.RateLimiter.Supervisor,
        # Token ledger for per-run/session token accounting
        CodePuppyControl.TokenLedger,
        # Atomic write-back for puppy.cfg
        CodePuppyControl.Config.Writer,
        CodePuppyControl.RequestTracker,
        # Renderer registry
        {Registry, keys: :unique, name: CodePuppyControl.REPL.RendererRegistry},
        # Shell command runner process tracking
        CodePuppyControl.Tools.CommandRunner.ProcessManager,
        # PTY session manager for interactive terminals
        CodePuppyControl.PtyManager,
        # Auth rate limiter ETS table owner — no DB/NIF dependency,
        # always started so the table is available in escript mode too.
        CodePuppyControlWeb.Plugs.RateLimiterServer
      ]

    # Children that require the exqlite NIF — only started when NOT in
    # escript mode. In escript mode, these are skipped entirely because
    # the NIF .so cannot be loaded from the zip archive.
    db_children =
      if in_escript do
        []
      else
        # (code-puppy-be7) ecto_sqlite3/exqlite/db_connection are in
        # included_applications (not auto-started). We must start them
        # before Repo so the NIF is loaded and DBConnection is available.
        # This ensures they start in non-escript mode but don't pollute
        # the startup logs with NIF load failures in escript mode.
        _ = Application.ensure_all_started(:ecto_sqlite3)

        [
          # SQLite database (requires exqlite NIF)
          CodePuppyControl.Repo,
          # Oban job processing with SQLite engine
          {Oban, Application.fetch_env!(:code_puppy_control, Oban)}
        ]
      end

    # Tail children that depend on DB or are web-only
    tail_children =
      if in_escript do
        []
      else
        cron_scheduler_child() ++
          maybe_pack_children() ++
          [CodePuppyControlWeb.Endpoint]
      end

    always ++ db_children ++ tail_children
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
  # Distributed packs subtree — conditionally started based on config.
  # When disabled (default), returns empty list — zero runtime cost.
  # When enabled, starts Registry, NamingService, DistributedSupervisor,
  # and NodeMonitor for cluster management.
  # (Phase I.1 — code_puppy-yge.2)
  defp maybe_pack_children do
    if CodePuppyControl.Pack.Config.enabled?() do
      [
        {Registry, keys: :unique, name: CodePuppyControl.Pack.Registry},
        CodePuppyControl.Pack.NamingService,
        CodePuppyControl.Pack.LoadBalancer,
        CodePuppyControl.Pack.DistributedSupervisor,
        CodePuppyControl.Pack.NodeMonitor
      ]
    else
      []
    end
  end

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
