defmodule CodePuppyControl.TestSupport.Reset.ServerStart do
  @moduledoc """
  Helpers for restarting globally named services used by the test reset flow.

  These functions are intentionally defensive: many tests exercise supervision
  behavior by terminating named processes, so reset/setup code must be able to
  recover missing children without causing unrelated tests to fail with
  `:noproc`/`no process` errors.

  App-supervised children are restarted through `CodePuppyControl.Supervisor`
  first. Direct `start_link/1` fallback is reserved for helpers that are not
  currently present in the application supervision tree, so a reset cannot make
  the suite green by accidentally running an unsupervised replacement singleton.
  """

  require Logger

  @app_supervisor CodePuppyControl.Supervisor
  @pubsub_child_id Phoenix.PubSub.Supervisor

  @doc """
  Ensures all required GenServers are started before resetting.

  This prevents test failures when GenServer.reset functions are called
  but the GenServer is not running.
  """
  @spec ensure_all_servers_started() :: :ok
  def ensure_all_servers_started do
    # Core application servers
    ensure_gen_server_started(CodePuppyControl.Repo)
    ensure_gen_server_started(CodePuppyControl.EventStore)
    ensure_gen_server_started(CodePuppyControl.RuntimeState)
    ensure_gen_server_started(CodePuppyControl.PolicyEngine)
    ensure_gen_server_started(CodePuppyControl.AgentModelPinning)
    ensure_gen_server_started(CodePuppyControl.ModelRegistry)
    ensure_gen_server_started(CodePuppyControl.ModelAvailability)
    ensure_gen_server_started(CodePuppyControl.ModelPacks)
    ensure_gen_server_started(CodePuppyControl.Tools.AgentCatalogue)
    ensure_gen_server_started(CodePuppyControl.RoundRobinModel)
    ensure_gen_server_started(CodePuppyControl.RequestTracker)
    ensure_gen_server_started(CodePuppyControl.Tools.CommandRunner.ProcessManager)

    # Concurrency limiter (needs supervisor started first)
    ensure_gen_server_started(CodePuppyControl.Concurrency.Supervisor)
    ensure_gen_server_started(CodePuppyControl.Concurrency.Limiter)

    # Parser registry
    ensure_gen_server_started(CodePuppyControl.Parsing.ParserRegistry)

    # DynamicSupervisors that must stay alive for tests
    # Agent.State.Supervisor is a DynamicSupervisor for per-{session,agent}
    # message history processes. Tests that call State.append_message/3
    # (via dispatch path) depend on it. (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.Agent.State.Supervisor)

    # Workflow.State is an Agent (not a GenServer).  Its start_link/1
    # delegates to Store.start_link/1 which requires an explicit
    # `name:` option to register the singleton.  The generic
    # `ensure_gen_server_started/1` passes `[]` (no name), so we
    # handle it specially.  (code_puppy-i1n)
    ensure_workflow_state_started()

    # ProviderRegistry must be available for ModelFactory tests.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.ModelFactory.ProviderRegistry)

    # Tool.Registry must be available for tool-related tests.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.Tool.Registry)

    # CLI SlashCommands Registry must be available for command tests.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.CLI.SlashCommands.Registry)

    # Callbacks.Registry must be available for hook/callback tests.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.Callbacks.Registry)

    # PubSub must be available for EventBus tests.
    # (code_puppy-i1n) PubSub can't be started with start_link([]),
    # so restart its app-supervised child id when needed.
    ensure_pubsub_started()

    # StagedChanges must be available for staging tests.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.Tools.StagedChanges)

    # Approvals must be available for file approval tests.
    ensure_gen_server_started(CodePuppyControl.Approvals)

    # RateLimiter.Supervisor + RateLimiter must be available.
    # (code_puppy-i1n)
    ensure_gen_server_started(CodePuppyControl.RateLimiter.Supervisor)
    ensure_gen_server_started(CodePuppyControl.RateLimiter)

    # Workflow.State (Agent-backed singleton) must be alive.
    # (code_puppy-i1n)
    # Already called above; no need to call twice.

    :ok
  end

  @doc """
  Starts Workflow.State with the correct name registration.

  Unlike most GenServers, `Workflow.State.start_link/1` delegates to
  `Store.start_link/1` which calls `Agent.start_link(fn -> ..., opts)`.
  It does NOT automatically register under `__MODULE__` — the caller
  must pass `name: CodePuppyControl.Workflow.State`.
  """
  @spec ensure_workflow_state_started() :: :ok
  def ensure_workflow_state_started do
    module = CodePuppyControl.Workflow.State

    case Process.whereis(module) do
      nil ->
        case restart_supervised_child(module) do
          :ok ->
            :ok

          {:error, :not_found} ->
            start_direct(module, [[name: module]])

          {:error, reason} ->
            Logger.warning(
              "Failed to restart #{inspect(module)} via supervisor: #{inspect(reason)}"
            )

            start_direct(module, [[name: module]])
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Ensure Phoenix.PubSub is started.

  PubSub can't be started with start_link([]) like a regular GenServer.
  Instead, we check if the PubSub name is registered and restart via
  the app supervisor if needed. (code_puppy-i1n)
  """
  @spec ensure_pubsub_started() :: :ok
  def ensure_pubsub_started do
    case Process.whereis(CodePuppyControl.PubSub) do
      nil ->
        case restart_supervised_child(CodePuppyControl.PubSub) do
          :ok ->
            wait_for_registered(CodePuppyControl.PubSub)

          {:error, reason} ->
            Logger.warning("Failed to restart PubSub via supervisor: #{inspect(reason)}")
            :ok
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Ensure a single GenServer is started.

  If the GenServer is not running, attempts to restart it under the application
  supervisor before falling back to a direct `start_link/1` for non-supervised
  helpers.
  """
  @spec ensure_gen_server_started(module()) :: :ok
  def ensure_gen_server_started(CodePuppyControl.PubSub), do: ensure_pubsub_started()

  def ensure_gen_server_started(module) do
    case Process.whereis(module) do
      nil ->
        case restart_supervised_child(module) do
          :ok ->
            wait_for_registered(module)

          {:error, :not_found} ->
            start_direct(module, [[]])

          {:error, {:name_missing, _pid} = reason} ->
            Logger.warning(
              "#{inspect(module)} app child is running but not registered: #{inspect(reason)}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to restart #{inspect(module)} via supervisor: #{inspect(reason)}"
            )

            :ok
        end

      _pid ->
        :ok
    end
  end

  # Attempts to restart a terminated child through its owning supervisor.
  # Works for children that were terminated with Supervisor.terminate_child/2
  # (spec kept, process dead).  Returns {:error, :not_found} when the module is
  # not part of a known test supervision tree, allowing an explicit direct-start
  # fallback only for non-supervised helpers.
  defp restart_supervised_child(module) do
    module
    |> supervisor_child_specs()
    |> Enum.reduce_while({:error, :not_found}, fn {supervisor, child_id}, _acc ->
      case restart_from_supervisor(supervisor, child_id) do
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        result -> {:halt, result}
      end
    end)
  end

  defp supervisor_child_specs(CodePuppyControl.PubSub),
    do: [{@app_supervisor, @pubsub_child_id}]

  defp supervisor_child_specs(CodePuppyControl.Concurrency.Limiter),
    do: [{CodePuppyControl.Concurrency.Supervisor, CodePuppyControl.Concurrency.Limiter}]

  defp supervisor_child_specs(CodePuppyControl.RateLimiter),
    do: [{CodePuppyControl.RateLimiter.Supervisor, CodePuppyControl.RateLimiter}]

  defp supervisor_child_specs(CodePuppyControl.Plugins.PackParallelism),
    do: [
      {CodePuppyControl.Plugins.PackParallelism.Supervisor,
       CodePuppyControl.Plugins.PackParallelism}
    ]

  defp supervisor_child_specs(module), do: [{@app_supervisor, module}]

  defp restart_from_supervisor(supervisor, child_id) do
    case Process.whereis(supervisor) do
      nil ->
        {:error, :not_found}

      _pid ->
        with {:ok, child_pid} <- supervisor_child_pid(supervisor, child_id) do
          case child_pid do
            :undefined -> normalize_restart_result(Supervisor.restart_child(supervisor, child_id))
            pid when is_pid(pid) -> {:error, {:name_missing, pid}}
          end
        end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp supervisor_child_pid(supervisor, child_id) do
    case Enum.find(Supervisor.which_children(supervisor), fn {id, _pid, _type, _modules} ->
           id == child_id
         end) do
      {^child_id, child_pid, _type, _modules} -> {:ok, child_pid}
      nil -> {:error, :not_found}
    end
  end

  defp normalize_restart_result({:ok, _pid}), do: :ok
  defp normalize_restart_result({:ok, _pid, _info}), do: :ok
  defp normalize_restart_result({:error, {:already_started, _pid}}), do: :ok
  defp normalize_restart_result({:error, reason}), do: {:error, reason}

  defp start_direct(module, args) do
    try do
      case apply(module, :start_link, args) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start #{inspect(module)} directly: #{inspect(reason)}")
          :ok
      end
    catch
      :exit, reason ->
        Logger.warning("Exit starting #{inspect(module)} directly: #{inspect(reason)}")
        :ok
    end
  end

  defp wait_for_registered(module, attempts \\ 5)
  defp wait_for_registered(_module, 0), do: :ok

  defp wait_for_registered(module, attempts) do
    case Process.whereis(module) do
      nil ->
        Process.sleep(10)
        wait_for_registered(module, attempts - 1)

      _pid ->
        :ok
    end
  end
end
