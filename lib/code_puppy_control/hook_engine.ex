defmodule CodePuppyControl.HookEngine do
  @moduledoc """
  Main HookEngine orchestration — processes events and executes hooks.

  Coordinates all hook engine components:
  - Loads and validates configuration
  - Matches events against hook patterns
  - Executes hooks with timeout and error handling
  - Aggregates results and determines blocking status

  Ported from `code_puppy/hook_engine/engine.py`.

  ## Quick Start

      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{"type" => "command", "command" => "./check.sh", "timeout" => 5000}
            ]
          }
        ]
      }

      {:ok, engine} = CodePuppyControl.HookEngine.start_link(config: my_config)

  ## Integration with CodePuppyControl.Callbacks

  The HookEngine can be wired into the existing callback system via
  `CodePuppyControl.HookEngine.CallbackAdapter`.  When registered as
  a `:pre_tool_call` / `:post_tool_call` callback, it automatically
  processes hook configs for those events.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.HookEngine.{Executor, Matcher, Models, Registry, Validator}
  alias Models.{EventData, ExecutionResult, HookConfig, HookRegistry, ProcessEventResult}

  # ── Client API ──────────────────────────────────────────────────

  @doc """
  Starts a HookEngine GenServer.

  ## Options

    - `:config` — Hook configuration map (optional, can be loaded later)
    - `:strict_validation` — Whether to raise on invalid config (default: true)
    - `:env_vars` — Additional environment variables for hook execution
    - `:name` — Registered name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Processes an event through the hook engine.

  Returns a `ProcessEventResult` struct.
  """
  @spec process_event(GenServer.server(), String.t(), EventData.t(), keyword()) ::
          ProcessEventResult.t()
  def process_event(engine \\ __MODULE__, event_type, event_data, opts \\ []) do
    sequential = Keyword.get(opts, :sequential, true)
    stop_on_block = Keyword.get(opts, :stop_on_block, true)

    GenServer.call(engine, {:process_event, event_type, event_data, sequential, stop_on_block})
  end

  @doc """
  Loads (or reloads) hook configuration into the engine.
  """
  @spec load_config(GenServer.server(), map()) :: :ok | {:error, String.t()}
  def load_config(engine \\ __MODULE__, config) do
    GenServer.call(engine, {:load_config, config})
  end

  @doc """
  Returns statistics about the loaded hook registry.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(engine \\ __MODULE__) do
    GenServer.call(engine, :get_stats)
  end

  @doc """
  Returns the list of hooks for a given event type.
  """
  @spec get_hooks_for_event(GenServer.server(), String.t()) :: [HookConfig.t()]
  def get_hooks_for_event(engine \\ __MODULE__, event_type) do
    GenServer.call(engine, {:get_hooks_for_event, event_type})
  end

  @doc """
  Counts hooks in the registry. Pass nil for total across all event types.
  """
  @spec count_hooks(GenServer.server(), String.t() | nil) :: non_neg_integer()
  def count_hooks(engine \\ __MODULE__, event_type \\ nil) do
    GenServer.call(engine, {:count_hooks, event_type})
  end

  @doc """
  Resets all once-executed hooks (new session).
  """
  @spec reset_once_hooks(GenServer.server()) :: :ok
  def reset_once_hooks(engine \\ __MODULE__) do
    GenServer.call(engine, :reset_once_hooks)
  end

  @doc """
  Adds a hook to the engine's registry programmatically.

  Deduplicated — adding a hook with the same ID as an existing one
  is a no-op.
  """
  @spec add_hook(GenServer.server(), String.t(), HookConfig.t()) :: :ok | :duplicate
  def add_hook(engine \\ __MODULE__, event_type, hook) do
    GenServer.call(engine, {:add_hook, event_type, hook})
  end

  @doc """
  Removes a hook by ID from the given event type.
  Returns true if found and removed.
  """
  @spec remove_hook(GenServer.server(), String.t(), String.t()) :: boolean()
  def remove_hook(engine \\ __MODULE__, event_type, hook_id) do
    GenServer.call(engine, {:remove_hook, event_type, hook_id})
  end

  @doc """
  Updates environment variables for hook execution.
  """
  @spec update_env_vars(GenServer.server(), map()) :: :ok
  def update_env_vars(engine \\ __MODULE__, env_vars) do
    GenServer.cast(engine, {:update_env_vars, env_vars})
  end

  @doc """
  Validates a hook configuration without loading it.
  """
  @spec validate_config(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_config(config) do
    Validator.validate_hooks_config(config)
  end

  @doc """
  Returns a formatted validation report for a config.
  """
  @spec validate_config_file(map()) :: String.t()
  def validate_config_file(config) do
    Validator.format_validation_report(Validator.validate_hooks_config(config))
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config)
    strict_validation = Keyword.get(opts, :strict_validation, true)
    env_vars = Keyword.get(opts, :env_vars, %{})

    state = %{
      registry: nil,
      strict_validation: strict_validation,
      env_vars: env_vars
    }

    if config do
      case load_config_internal(config, strict_validation) do
        {:ok, registry} ->
          {:ok, %{state | registry: registry}}

        {:error, error_msg} ->
          if strict_validation do
            {:stop, {:invalid_config, error_msg}}
          else
            Logger.warning("Hook configuration has errors: #{error_msg}")
            {:ok, %{state | registry: %HookRegistry{}}}
          end
      end
    else
      {:ok, %{state | registry: %HookRegistry{}}}
    end
  end

  @impl true
  def handle_call(
        {:process_event, event_type, event_data, sequential, stop_on_block},
        _from,
        state
      ) do
    result =
      do_process_event(
        state.registry,
        event_type,
        event_data,
        sequential,
        stop_on_block,
        state.env_vars
      )

    # Update registry with once-hook tracking
    state =
      if result.executed_hooks > 0 and state.registry do
        matching_hooks = get_all_matching_hooks(state.registry, event_type, event_data)

        updated_registry =
          Enum.zip(matching_hooks, result.results)
          |> Enum.reduce(state.registry, fn {hook, exec_result}, reg ->
            if hook.once and ExecutionResult.success?(exec_result) do
              Registry.mark_hook_executed(reg, hook.id)
            else
              reg
            end
          end)

        %{state | registry: updated_registry}
      else
        state
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:load_config, config}, _from, state) do
    case load_config_internal(config, state.strict_validation) do
      {:ok, registry} ->
        Logger.info("Loaded hook configuration: #{Registry.count_hooks(registry)} total hooks")
        {:reply, :ok, %{state | registry: registry}}

      {:error, error_msg} ->
        if state.strict_validation do
          {:reply, {:error, error_msg}, state}
        else
          Logger.warning("Hook configuration has errors: #{error_msg}")
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      case state.registry do
        nil -> %{total_hooks: 0, error: "No registry loaded"}
        reg -> Registry.get_stats(reg)
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_hooks_for_event, event_type}, _from, state) do
    hooks =
      case state.registry do
        nil -> []
        reg -> Registry.get_hooks_for_event(reg, event_type)
      end

    {:reply, hooks, state}
  end

  @impl true
  def handle_call({:count_hooks, event_type}, _from, state) do
    count =
      case state.registry do
        nil -> 0
        reg -> Registry.count_hooks(reg, event_type)
      end

    {:reply, count, state}
  end

  @impl true
  def handle_call(:reset_once_hooks, _from, state) do
    registry =
      case state.registry do
        nil -> nil
        reg -> Registry.reset_once_hooks(reg)
      end

    {:reply, :ok, %{state | registry: registry}}
  end

  @impl true
  def handle_call({:add_hook, event_type, hook}, _from, state) do
    {registry, result} =
      case state.registry do
        nil -> Registry.add_hook(%HookRegistry{}, event_type, hook)
        reg -> Registry.add_hook(reg, event_type, hook)
      end

    {:reply, result, %{state | registry: registry}}
  end

  @impl true
  def handle_call({:remove_hook, event_type, hook_id}, _from, state) do
    case state.registry do
      nil ->
        {:reply, false, state}

      reg ->
        {updated_reg, found} = Registry.remove_hook(reg, event_type, hook_id)
        {:reply, found, %{state | registry: updated_reg}}
    end
  end

  @impl true
  def handle_cast({:update_env_vars, env_vars}, state) do
    {:noreply, %{state | env_vars: Map.merge(state.env_vars, env_vars)}}
  end

  # ── Private ─────────────────────────────────────────────────────

  @spec load_config_internal(map(), boolean()) ::
          {:ok, HookRegistry.t()} | {:error, String.t()}
  defp load_config_internal(config, _strict_validation) do
    case Validator.validate_hooks_config(config) do
      {:ok, _valid_config} ->
        registry = Registry.build_from_config(config)
        {:ok, registry}

      {:error, errors} ->
        error_msg = Validator.format_validation_report({:error, errors})
        {:error, error_msg}
    end
  end

  @spec do_process_event(
          HookRegistry.t() | nil,
          String.t(),
          EventData.t(),
          boolean(),
          boolean(),
          map()
        ) ::
          ProcessEventResult.t()
  defp do_process_event(nil, _event_type, _event_data, _sequential, _stop_on_block, _env_vars) do
    %ProcessEventResult{blocked: false, executed_hooks: 0, results: [], total_duration_ms: 0.0}
  end

  defp do_process_event(registry, event_type, event_data, sequential, stop_on_block, env_vars) do
    start_time = System.monotonic_time(:millisecond)

    all_hooks = Registry.get_hooks_for_event(registry, event_type)

    if all_hooks == [] do
      duration = (System.monotonic_time(:millisecond) - start_time) * 1.0

      %ProcessEventResult{
        blocked: false,
        executed_hooks: 0,
        results: [],
        total_duration_ms: duration
      }
    else
      matching_hooks = filter_hooks_by_matcher(all_hooks, event_data)

      if matching_hooks == [] do
        duration = (System.monotonic_time(:millisecond) - start_time) * 1.0

        %ProcessEventResult{
          blocked: false,
          executed_hooks: 0,
          results: [],
          total_duration_ms: duration
        }
      else
        Logger.debug(fn ->
          "Processing #{event_type}: #{length(matching_hooks)} matching hook(s) for tool '#{event_data.tool_name}'"
        end)

        opts = [env_vars: env_vars, stop_on_block: stop_on_block]

        results =
          if sequential do
            Executor.execute_hooks_sequential(matching_hooks, event_data, opts)
          else
            Executor.execute_hooks_parallel(matching_hooks, event_data, opts)
          end

        blocking_result = Executor.get_blocking_result(results)
        blocked = blocking_result != nil

        blocking_reason =
          if blocked do
            "Hook '#{blocking_result.hook_command}' failed: " <>
              (blocking_result.error || blocking_result.stderr || "blocked (no details provided)")
          else
            nil
          end

        total_duration = Enum.reduce(results, 0.0, fn r, acc -> acc + r.duration_ms end)

        %ProcessEventResult{
          blocked: blocked,
          executed_hooks: length(results),
          results: results,
          blocking_reason: blocking_reason,
          total_duration_ms: total_duration
        }
      end
    end
  end

  @spec filter_hooks_by_matcher([HookConfig.t()], EventData.t()) :: [HookConfig.t()]
  defp filter_hooks_by_matcher(hooks, %EventData{} = event_data) do
    Enum.filter(hooks, fn hook ->
      try do
        Matcher.matches(hook.matcher, event_data.tool_name, event_data.tool_args)
      rescue
        e ->
          Logger.error("Error matching hook '#{hook.matcher}': #{Exception.message(e)}")
          false
      catch
        _, _ ->
          Logger.error("Error matching hook '#{hook.matcher}': crashed")
          false
      end
    end)
  end

  @spec get_all_matching_hooks(HookRegistry.t(), String.t(), EventData.t()) :: [HookConfig.t()]
  defp get_all_matching_hooks(registry, event_type, %EventData{} = event_data) do
    all_hooks = Registry.get_hooks_for_event(registry, event_type)
    filter_hooks_by_matcher(all_hooks, event_data)
  end
end
