defmodule CodePuppyControl.TestSupport.Reset do
  @moduledoc """
  Comprehensive reset for all stateful components.

  This module provides a `reset_all/0` function that clears all stateful
  GenServers, ETS tables, and dynamic supervisor children to ensure
  complete test isolation.

  ## Usage

  Call `reset_all/0` in your test setup:

      setup do
        CodePuppyControl.TestSupport.Reset.reset_all()
        :ok
      end

  ## Reset Order

  Resets are performed in reverse dependency order to avoid issues:

  1. Ensure all GenServers are started (CRITICAL - before any reset calls)
  2. DynamicSupervisor children terminated first (Run, MCP)
  3. GenServer state resets (ProcessManager, RequestTracker)
  4. GenServer ETS resets (PolicyEngine, ModelAvailability, RoundRobinModel, etc.)
  5. ETS-only table clears (AgentModelPinning, Limiter counters, Token cache)
  6. Parser registry cleared and re-registered

  ## Notes

  - All GenServer calls are wrapped in `Process.whereis/1` checks to avoid
    crashes when servers are not running
  - ETS operations are wrapped in try/rescue for tables that may not exist
  - The Limiter preserves its limit values, only resetting counters to 0
  """

  require Logger

  alias CodePuppyControl.TestSupport.Reset
  alias CodePuppyControl.TestSupport.Reset.ServerStart

  @doc """
  Reset everything — call in test setup to ensure test isolation.

  Clears all GenServer state, ETS tables, and terminates dynamic supervisor
  children in the correct dependency order.
  """
  @spec reset_all() :: :ok
  def reset_all do
    # FIRST: Ensure all GenServers are running BEFORE attempting any resets
    # This prevents crashes when calling functions on stopped GenServers
    ensure_all_servers_started()

    # Order matters: reset in reverse dependency order
    # First: terminate dynamic supervisor children (top of tree)
    Reset.DynamicSupervisors.terminate_all()

    # Second: reset GenServers that track process state
    Reset.GenServers.reset_process_state()

    # Third: ensure critical supervisors are running
    Reset.Supervisors.ensure_started()

    # Fourth: reset GenServers that use ETS
    Reset.GenServers.reset_via_call()

    # Fifth: ensure ETS-only GenServers are started (no reset function)
    Reset.ensure_ets_started()

    # Sixth: clear ETS-only tables
    Reset.ETS.clear_tables()

    # Seventh: reset parser registry and re-register parsers
    Reset.ParserRegistry.reset_and_register()

    :ok
  end

  # ============================================================================
  # Ensure All Servers Started (CRITICAL - must be first!)
  # ============================================================================

  defdelegate ensure_all_servers_started(), to: ServerStart
  defdelegate ensure_workflow_state_started(), to: ServerStart
  defdelegate ensure_pubsub_started(), to: ServerStart
  defdelegate ensure_gen_server_started(module), to: ServerStart

  # ============================================================================
  # DynamicSupervisor Management
  # ============================================================================

  defmodule DynamicSupervisors do
    @moduledoc """
    Management of DynamicSupervisor children.
    """

    @doc """
    Terminate all children in dynamic supervisors.

    This terminates all active runs and MCP servers.
    """
    @spec terminate_all() :: :ok
    def terminate_all do
      terminate_run_children()
      terminate_mcp_children()
      :ok
    end

    defp terminate_run_children do
      # Terminate executor processes first (they reference Run.State PIDs)
      terminate_executor_children()

      # Then terminate run state processes
      terminate_run_state_children()
    end

    defp terminate_executor_children do
      case Process.whereis(CodePuppyControl.Run.Executor.Supervisor) do
        nil ->
          :ok

        _pid ->
          children = DynamicSupervisor.which_children(CodePuppyControl.Run.Executor.Supervisor)

          Enum.each(children, fn
            {:undefined, pid, :worker, _} when is_pid(pid) ->
              DynamicSupervisor.terminate_child(CodePuppyControl.Run.Executor.Supervisor, pid)

            _ ->
              :ok
          end)
      end
    end

    defp terminate_run_state_children do
      case Process.whereis(CodePuppyControl.Run.Supervisor) do
        nil ->
          :ok

        _pid ->
          children = CodePuppyControl.Run.Supervisor.list_runs()

          Enum.each(children, fn {run_id, _pid} ->
            CodePuppyControl.Run.Supervisor.terminate_run(run_id)
          end)

          if length(children) > 0 do
            Logger.debug("Reset: terminated #{length(children)} run processes")
          end
      end
    end

    defp terminate_mcp_children do
      case Process.whereis(CodePuppyControl.MCP.Supervisor) do
        nil ->
          :ok

        _pid ->
          children = CodePuppyControl.MCP.Supervisor.list_servers()

          Enum.each(children, fn server_id ->
            CodePuppyControl.MCP.Supervisor.stop_server(server_id)
          end)

          if length(children) > 0 do
            Logger.debug("Reset: terminated #{length(children)} MCP servers")
          end
      end
    end
  end

  # ============================================================================
  # GenServer State Reset
  # ============================================================================

  defmodule GenServers do
    @moduledoc """
    Reset functions for GenServer-based state.
    """

    alias CodePuppyControl.{
      PolicyEngine,
      ModelAvailability,
      RoundRobinModel,
      EventStore,
      RuntimeState,
      ModelRegistry
    }

    alias CodePuppyControl.Tools.{AgentCatalogue, CommandRunner}

    @doc """
    Reset GenServers that track process/pid state.

    These need special handling because they track references to
    external processes.
    """
    @spec reset_process_state() :: :ok
    def reset_process_state do
      # RequestTracker: clear pending requests and cancel timers
      reset_request_tracker()

      # ProcessManager: clear all tracked commands
      reset_process_manager()

      :ok
    end

    @doc """
    Reset GenServers via their public reset functions.
    """
    @spec reset_via_call() :: :ok
    def reset_via_call do
      # ModelRegistry: reload configs (ensure started first - needed by other tests)
      reset_with_restart(ModelRegistry, :reload, [])

      # PolicyEngine: clear all rules (ensure started first)
      reset_with_restart(PolicyEngine, :reset, [])

      # ModelAvailability: clear health states (ensure started first)
      reset_with_restart(ModelAvailability, :reset_all, [])

      # RoundRobinModel: reset rotation state (ensure started first)
      reset_with_restart(RoundRobinModel, :reset, [])

      # Callbacks.Registry: clear test-installed callbacks so hooks from one
      # test cannot leak into command-security or tool-runner checks. Re-register
      # core Workflow.State handlers after clearing. (code_puppy-i1n)
      reset_callbacks()

      # EventStore: clear all events
      safe_call(EventStore, :clear_all)

      # AgentCatalogue: clear all agents
      safe_call(AgentCatalogue, :clear_catalogue)

      # RuntimeState: reset autosave_id and session_model (ensure started first)
      reset_with_restart(RuntimeState, :reset_autosave_id, [])
      safe_cast(RuntimeState, :reset_session_model)

      # FeatureFlags: reset all flags to false (code_puppy-djs.4)
      reset_with_restart(CodePuppyControl.FeatureFlags, :reset_all, [])

      # Rollout: reset counters and clear rollout percentages (code_puppy-djs.6)
      safe_call(CodePuppyControl.Rollout, :reset_counters)

      for cap <- CodePuppyControl.FeatureFlags.capabilities() do
        safe_call(CodePuppyControl.Rollout, :set_percentage, [cap, 0])
        safe_call(CodePuppyControl.Rollout, :set_error_threshold, [cap, 0.10])
      end

      # ModelPacks: reset current pack to default "single"
      safe_call(CodePuppyControl.ModelPacks, :set_current_pack, ["single"])

      # CodeContext: invalidate cache
      reset_code_context()

      # Gitignore: clear cache
      reset_gitignore()

      :ok
    end

    # Ensures GenServer is running (starts if needed) then calls reset function
    defp reset_with_restart(module, function, args) do
      case Process.whereis(module) do
        nil ->
          # GenServer not running - try to start it
          try do
            apply(module, :start_link, [[]])
          catch
            :exit, _ -> :ok
          end

          # Wait a moment for supervisor to potentially restart
          Process.sleep(50)

        _pid ->
          :ok
      end

      # Now safe to call the reset function
      safe_call(module, function, args)
    end

    defp reset_request_tracker do
      # RequestTracker needs a custom reset - ensure it's running with fresh state
      # We don't try to stop the GenServer as that causes exit signals
      # Instead, we just ensure it's running - if it was already running, 
      # any pending state will be naturally cleared by the reset_all flow
      Reset.ensure_gen_server_started(CodePuppyControl.RequestTracker)
    end

    defp reset_process_manager do
      # Ensure ProcessManager is running, then kill all tracked processes
      Reset.ensure_gen_server_started(CommandRunner.ProcessManager)
      safe_call(CommandRunner.ProcessManager, :kill_all)
    end

    defp reset_callbacks do
      Reset.ensure_gen_server_started(CodePuppyControl.Callbacks.Registry)

      try do
        CodePuppyControl.Callbacks.clear()
        CodePuppyControl.Workflow.State.register_callback_handlers()
      catch
        :exit, _ -> :ok
      end
    end

    defp reset_code_context do
      # CodeContext.invalidate_cache/1 clears the ETS cache
      try do
        CodePuppyControl.CodeContext.invalidate_cache(nil)
      rescue
        _ -> :ok
      end
    end

    defp reset_gitignore do
      safe_call(CodePuppyControl.Gitignore, :clear_cache)
    end

    defp safe_call(module, function, args \\ []) do
      case Process.whereis(module) do
        nil -> :ok
        _pid -> apply(module, function, args)
      end
    catch
      :exit, _ -> :ok
    end

    defp safe_cast(module, function, args \\ []) do
      case Process.whereis(module) do
        nil -> :ok
        _pid -> apply(module, function, args)
      end
    catch
      :exit, _ -> :ok
    end
  end

  # ============================================================================
  # Supervisor Management
  # ============================================================================

  defmodule Supervisors do
    @moduledoc """
    Ensure critical supervisors are running.
    """

    @doc """
    Start supervisors that are needed for tests.
    """
    @spec ensure_started() :: :ok
    def ensure_started do
      # Concurrency.Supervisor starts the Limiter GenServer
      ensure_supervisor_started(CodePuppyControl.Concurrency.Supervisor)

      :ok
    end

    defp ensure_supervisor_started(module) do
      case Process.whereis(module) do
        nil ->
          try do
            apply(module, :start_link, [[]])
          catch
            :exit, _ -> :ok
          end

          # Wait for supervisor to fully start and children to be ready
          Process.sleep(100)

        _pid ->
          :ok
      end
    end
  end

  # ============================================================================
  # Ensure ETS-only GenServers are started
  # ============================================================================

  def ensure_ets_started do
    # AgentModelPinning uses ETS but has no global reset function
    # Just ensure it's started; ETS.clear_tables will clear the table
    ensure_gen_server_started(CodePuppyControl.AgentModelPinning)

    # Ensure Ecto Repo is started for database tests
    ensure_repo_started()

    :ok
  end

  defp ensure_repo_started do
    case Process.whereis(CodePuppyControl.Repo) do
      nil ->
        try do
          CodePuppyControl.Repo.start_link()
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)

      _pid ->
        :ok
    end
  end

  # ============================================================================
  # ETS Table Management
  # ============================================================================

  defmodule ETS do
    @moduledoc """
    Direct ETS table clearing for tables without GenServer reset functions.
    """

    @doc """
    Clear all ETS tables that don't have GenServer-mediated reset functions.
    """
    @spec clear_tables() :: :ok
    def clear_tables do
      clear_agent_model_pins()
      clear_concurrency_limits()
      clear_token_estimate_cache()
      clear_model_last_resort()
      :ok
    end

    # AgentModelPinning ETS table
    defp clear_agent_model_pins do
      try do
        :ets.delete_all_objects(:agent_model_pins)
      rescue
        ArgumentError -> :ok
      end
    end

    # Limiter: reset counters and queued waiters while preserving limits
    defp clear_concurrency_limits do
      case Process.whereis(CodePuppyControl.Concurrency.Limiter) do
        nil ->
          reset_concurrency_limit_counters()

        _pid ->
          CodePuppyControl.Concurrency.Limiter.reset()
      end
    catch
      :exit, _ -> reset_concurrency_limit_counters()
    end

    defp reset_concurrency_limit_counters do
      try do
        # Get current limits
        entries = :ets.tab2list(:concurrency_limits)

        # Reset each counter to 0 while preserving the limit
        Enum.each(entries, fn {type, _current, limit} ->
          :ets.insert(:concurrency_limits, {type, 0, limit})
        end)
      rescue
        ArgumentError -> :ok
      end
    end

    # Tokens.Estimator cache
    defp clear_token_estimate_cache do
      # Ensure the table exists (creates it if missing, using same opts as the module)
      ensure_token_estimate_cache_exists()

      try do
        if :ets.whereis(:token_estimate_cache) != :undefined do
          :ets.delete_all_objects(:token_estimate_cache)
        end
      rescue
        ArgumentError -> :ok
      end
    end

    # Ensure the ETS table exists, creating it if necessary.
    # Replicates the table creation from Tokens.Estimator.init_ets/0
    defp ensure_token_estimate_cache_exists do
      if :ets.whereis(:token_estimate_cache) == :undefined do
        try do
          :ets.new(:token_estimate_cache, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          # Table was created by another process
          ArgumentError -> :ok
        end
      end

      :ok
    end

    # ModelAvailability backup clear for last_resort table
    defp clear_model_last_resort do
      try do
        :ets.delete_all_objects(:model_last_resort)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  # ============================================================================
  # Parser Registry Management
  # ============================================================================

  defmodule ParserRegistry do
    @moduledoc """
    Parser registry reset and re-registration.
    """

    @doc """
    Clear the parser registry and re-register all parsers.

    This ensures that parsers are in a known state after reset.
    """
    @spec reset_and_register() :: :ok
    def reset_and_register do
      registry = CodePuppyControl.Parsing.ParserRegistry

      # Clear existing parsers
      case Process.whereis(registry) do
        nil ->
          # Registry not running, try to start it
          registry.start_link()

        _pid ->
          registry.clear()
      end

      # Re-register all parsers
      CodePuppyControl.Parsing.Parsers.register_all()

      :ok
    end
  end
end
