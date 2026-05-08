defmodule CodePuppyControl.HookEngine.CallbackAdapter do
  @moduledoc """
  Integrates HookEngine into the existing CodePuppyControl.Callbacks system.

  This adapter registers itself as a `:pre_tool_call` and `:post_tool_call`
  callback so that any configured hook scripts run automatically when tools
  are invoked.

  ## Usage

      # One-time setup (typically in application startup):
      CodePuppyControl.HookEngine.CallbackAdapter.register(engine_pid)

  ## Idempotency

  `register/1` uses **stable named function captures** (`&__MODULE__.pre_tool_callback/3`
  and `&__MODULE__.post_tool_callback/5`).  Because these are module-level
  function references, they compare equal across repeated calls, and the
  `Callbacks.Registry` deduplication (`fun in existing`) works correctly.

  The engine reference is stored in a named ETS table so that it survives
  HookEngine process restarts — when the engine crashes and is restarted
  by its supervisor, calling `register/1` again updates the stored reference
  without creating duplicate callbacks.

  ## Callback Flow

  1. A tool is about to be called → `:pre_tool_call` fires
  2. The adapter constructs an `EventData` and runs `HookEngine.process_event/4`
  3. If the result is blocked, the adapter returns `%{blocked: true, reason: ...}`
  4. If not blocked, returns `nil` (pass-through)

  ## Python Semantics Preserved

  The merge semantics from `code_puppy/callbacks.py` are respected:
  - For `:pre_tool_call` (merge: `:noop`), the adapter returns either
    `%{blocked: true}` or `nil`, matching the Python `run_shell_command`
    hook pattern.
  - For `:post_tool_call` (merge: `:noop`), the adapter returns `nil`
    (observer only — post hooks cannot block).

  ## Post-Tool Context

  The `:post_tool_call` callback receives `result` and `duration_ms`
  arguments per the hook signature (arity 5). These are forwarded into
  `EventData.context` so that hook scripts can access tool results and
  timing via the stdin JSON payload.
  """

  require Logger

  alias CodePuppyControl.HookEngine
  alias CodePuppyControl.HookEngine.Models.EventData

  # Named ETS table for adapter state (engine reference).
  # Created on first `register/1` call.
  @adapter_store :hook_engine_callback_adapter

  @doc """
  Registers the adapter as a `:pre_tool_call` and `:post_tool_call`
  callback with `CodePuppyControl.Callbacks`.

  `engine` is the PID or registered name of the `HookEngine` GenServer.
  If no engine is passed, defaults to `CodePuppyControl.HookEngine`.

  Idempotent — safe to call multiple times. Uses stable named function
  captures so `Callbacks.Registry` deduplication works correctly.
  """
  @spec register(GenServer.server()) :: :ok
  def register(engine \\ HookEngine) do
    ensure_adapter_store()
    # Store/update engine reference (survives engine restart)
    :ets.insert(@adapter_store, {:engine_ref, engine})

    # Stable named function captures — compare equal across repeated calls
    pre_fn = &__MODULE__.pre_tool_callback/3
    post_fn = &__MODULE__.post_tool_callback/5

    CodePuppyControl.Callbacks.register(:pre_tool_call, pre_fn)
    CodePuppyControl.Callbacks.register(:post_tool_call, post_fn)

    :ok
  end

  @doc """
  Returns the currently stored engine reference (for introspection/testing).
  """
  @spec get_engine_ref() :: GenServer.server()
  def get_engine_ref do
    case :ets.lookup(@adapter_store, :engine_ref) do
      [{:engine_ref, engine}] -> engine
      [] -> HookEngine
    end
  end

  # ── Stable Named Callbacks ──────────────────────────────────────

  @doc false
  @spec pre_tool_callback(String.t(), map(), term()) ::
          %{blocked: true, reason: String.t()} | nil
  def pre_tool_callback(tool_name, tool_args, _context) do
    handle_pre_tool_call(get_engine_ref(), tool_name, tool_args)
  end

  @doc false
  @spec post_tool_callback(String.t(), map(), term(), term(), term()) :: nil
  def post_tool_callback(tool_name, tool_args, result, duration_ms, _context) do
    handle_post_tool_call(get_engine_ref(), tool_name, tool_args, result, duration_ms)
  end

  # ── Handler Logic ──────────────────────────────────────────────

  @doc """
  Handles a `:pre_tool_call` event by processing it through the HookEngine.

  Returns `%{blocked: true, reason: "..."}` if any hook blocks, or `nil`
  to allow the operation.
  """
  @spec handle_pre_tool_call(GenServer.server(), String.t(), map()) ::
          %{blocked: true, reason: String.t()} | nil
  def handle_pre_tool_call(engine, tool_name, tool_args) do
    event_data =
      EventData.new(
        event_type: "PreToolUse",
        tool_name: tool_name,
        tool_args: tool_args
      )

    result = HookEngine.process_event(engine, "PreToolUse", event_data)

    if result.blocked do
      Logger.warning("PreToolUse hook blocked: #{result.blocking_reason}")
      %{blocked: true, reason: result.blocking_reason || "blocked by hook"}
    else
      nil
    end
  rescue
    e ->
      Logger.error("HookEngine pre_tool_call adapter error: #{Exception.message(e)}")
      # Fail-open: don't block on adapter errors
      nil
  catch
    :exit, _ ->
      # Engine process not alive — fail-open
      nil
  end

  @doc """
  Handles a `:post_tool_call` event by processing it through the HookEngine.

  Post hooks are observers only — they cannot block.
  Returns `nil` always.

  `result` and `duration_ms` are included in the EventData context
  so that hook scripts can access tool results and timing information
  via the stdin JSON payload.
  """
  @spec handle_post_tool_call(GenServer.server(), String.t(), map(), term(), term()) :: nil
  def handle_post_tool_call(engine, tool_name, tool_args, result, duration_ms) do
    context = %{"result" => result, "duration_ms" => duration_ms}

    event_data =
      EventData.new(
        event_type: "PostToolUse",
        tool_name: tool_name,
        tool_args: tool_args,
        context: context
      )

    _result = HookEngine.process_event(engine, "PostToolUse", event_data)
    nil
  rescue
    e ->
      Logger.error("HookEngine post_tool_call adapter error: #{Exception.message(e)}")
      nil
  catch
    :exit, _ ->
      nil
  end

  # ── Private ───────────────────────────────────────────────────

  @spec ensure_adapter_store() :: :ok
  defp ensure_adapter_store do
    if :ets.whereis(@adapter_store) == :undefined do
      :ets.new(@adapter_store, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])
    end

    :ok
  end
end
