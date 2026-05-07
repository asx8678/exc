defmodule CodePuppyControl.Callbacks do
  @moduledoc """
  Public API for the callback registry and trigger system.

  This module is the primary interface for registering, unregistering,
  and triggering callback hooks. It delegates storage to the
  `CodePuppyControl.Callbacks.Registry` GenServer and merge logic to
  `CodePuppyControl.Callbacks.Merge`.

  ## Quick Start

      # Register a callback
      CodePuppyControl.Callbacks.register(:startup, fn ->
        IO.puts("Application started!")
      end)

      # Trigger callbacks for a hook
      CodePuppyControl.Callbacks.trigger(:startup)

      # Unregister
      CodePuppyControl.Callbacks.unregister(:startup, my_fun)

  ## Merge Semantics

  When multiple callbacks are registered for a hook, their results
  are merged according to the hook's declared strategy:

  - `:concat_str` — string results concatenated with newlines
  - `:extend_list` — list results flattened into one list
  - `:update_map` — map results deep-merged (later wins)
  - `:or_bool` — boolean results OR'd (any true wins)
  - `:noop` — results collected as-is

  ## Error Handling

  If a callback raises an exception, it is caught and replaced with
  the `:callback_failed` sentinel. The host process is never killed.
  Failed callbacks are logged at the `:error` level.
  """

  require Logger

  alias CodePuppyControl.Callbacks.{Hooks, Merge, Registry}

  # ── Shutdown Reentrancy Guard ───────────────────────────────────
  # 3-state machine: :idle → :running → :complete
  # Prevents recursive cleanup when signals arrive during shutdown.
  # Originally ported from the legacy Python callback system.

  @shutdown_table :code_puppy_shutdown_stage

  @doc """
  Returns the current shutdown stage.

  One of `:idle`, `:running`, or `:complete`.
  """
  @spec shutdown_stage() :: :idle | :running | :complete
  def shutdown_stage do
    case :ets.whereis(@shutdown_table) do
      :undefined ->
        :idle

      _ref ->
        case :ets.lookup(@shutdown_table, :stage) do
          [{:stage, stage}] -> stage
          [] -> :idle
        end
    end
  end

  @doc """
  Resets the shutdown stage to `:idle`.

  Only intended for testing. Do not call in production code.
  """
  @spec reset_shutdown_stage() :: :ok
  def reset_shutdown_stage do
    ensure_shutdown_table()
    :ets.insert(@shutdown_table, {:stage, :idle})
    :ok
  end

  @doc """
  Triggers shutdown callbacks with reentrancy protection.

  Implements a 3-state machine (:idle → :running → :complete) to prevent
  recursive cleanup when signals arrive during an ongoing shutdown.

  Returns the merged result, or `nil` if shutdown is already running/complete.
  """
  @spec trigger_shutdown() :: term()
  def trigger_shutdown do
    ensure_shutdown_table()

    # Try to transition :idle → :running atomically
    case :ets.lookup(@shutdown_table, :stage) do
      [{:stage, :idle}] ->
        :ets.insert(@shutdown_table, {:stage, :running})

        try do
          trigger(:shutdown)
        after
          :ets.insert(@shutdown_table, {:stage, :complete})
        end

      [{:stage, :running}] ->
        Logger.warning("Shutdown triggered recursively (already running); ignoring")
        nil

      [{:stage, :complete}] ->
        Logger.debug("Shutdown already complete; ignoring duplicate request")
        nil
    end
  end

  defp ensure_shutdown_table do
    case :ets.whereis(@shutdown_table) do
      :undefined ->
        :ets.new(@shutdown_table, [:set, :public, :named_table])
        :ets.insert(@shutdown_table, {:stage, :idle})
        :ok

      _ref ->
        :ok
    end
  end

  # ── Registration ────────────────────────────────────────────────

  @doc """
  Registers a callback function for the given hook.

  Idempotent: registering the same function twice for the same hook
  is a no-op. Callbacks execute in registration order.

  Raises `ArgumentError` if the hook name is not a known hook.

  ## Examples

      CodePuppyControl.Callbacks.register(:startup, fn -> IO.puts("started") end)
  """
  @spec register(atom(), function()) :: :ok
  def register(hook_name, fun) when is_atom(hook_name) and is_function(fun) do
    unless Hooks.valid?(hook_name) do
      raise ArgumentError,
            "Unknown hook: #{inspect(hook_name)}. Known hooks: #{inspect(Hooks.names())}"
    end

    Registry.register(hook_name, fun)
  end

  @doc """
  Unregisters a callback function from the given hook.

  Returns `true` if the callback was found and removed, `false` otherwise.

  ## Examples

      CodePuppyControl.Callbacks.unregister(:startup, my_fun)
  """
  @spec unregister(atom(), function()) :: boolean()
  def unregister(hook_name, fun) when is_atom(hook_name) and is_function(fun) do
    Registry.unregister(hook_name, fun)
  end

  # ── Triggering ──────────────────────────────────────────────────

  @doc """
  Triggers all callbacks registered for the given hook (synchronously).

  Callbacks execute in registration order. Results are merged according
  to the hook's declared merge strategy. Failed callbacks are replaced
  with `:callback_failed` and logged.

  Returns the merged result, or `nil` if no callbacks are registered.

  ## Examples

      CodePuppyControl.Callbacks.trigger(:load_prompt)
      #=> "plugin1 instructions\\nplugin2 instructions"
  """
  @spec trigger(atom(), [term()]) :: term()
  def trigger(hook_name, args \\ []) when is_atom(hook_name) and is_list(args) do
    callbacks = Registry.get_callbacks(hook_name)

    if callbacks == [] do
      nil
    else
      results = execute_callbacks(hook_name, callbacks, args)
      merge_strategy = Hooks.merge_type(hook_name)
      Merge.merge_results(results, merge_strategy)
    end
  end

  @doc """
  Triggers all callbacks registered for the given hook concurrently.

  All callbacks are spawned as separate tasks and awaited. Results are
  collected in registration order (not completion order), then merged
  according to the hook's declared merge strategy.

  Only appropriate for hooks declared with `async: true` in `Hooks`.

  Returns `{:ok, merged_result}` or `{:error, :not_async}` if the hook
  doesn't support async execution.

  ## Examples

      CodePuppyControl.Callbacks.trigger_async(:stream_event, ["token", data, session_id])
      #=> {:ok, nil}
  """
  @spec trigger_async(atom(), [term()]) :: {:ok, term()} | {:error, :not_async}
  def trigger_async(hook_name, args \\ []) when is_atom(hook_name) and is_list(args) do
    if Hooks.async?(hook_name) do
      callbacks = Registry.get_callbacks(hook_name)

      if callbacks == [] do
        {:ok, nil}
      else
        results = execute_callbacks_async(hook_name, callbacks, args)
        merge_strategy = Hooks.merge_type(hook_name)
        {:ok, Merge.merge_results(results, merge_strategy)}
      end
    else
      {:error, :not_async}
    end
  end

  @doc """
  Triggers callbacks sequentially with chaining: each callback
  receives the current effective args updated from the prior result.

  Designed for hooks like `:get_model_system_prompt` where callbacks
  should cooperate by reading the prior result's `instructions` and
  `user_prompt` keys and returning an updated map.

  `key_to_index` maps result-map keys to arg positions so chaining
  can feed prior results forward. For `:get_model_system_prompt`:

      key_to_index: [instructions: 1, user_prompt: 2]

  Means: if a callback returns `%{instructions: "...", user_prompt: "..."}`,
  the next callback receives those values at arg positions 1 and 2.

  Returns the merged result using the hook's declared merge strategy,
  or `nil` if no callbacks are registered.
  """
  @spec trigger_chained(atom(), [term()], [{atom(), non_neg_integer()}]) :: term()
  def trigger_chained(hook_name, args, key_to_index \\ [])
      when is_atom(hook_name) and is_list(args) and is_list(key_to_index) do
    callbacks = Registry.get_callbacks(hook_name)

    if callbacks == [] do
      nil
    else
      {results, _final_args} =
        Enum.reduce(callbacks, {[], args}, fn callback, {acc, current_args} ->
          result =
            try do
              apply(callback, current_args)
            rescue
              e ->
                Logger.error(
                  "Chained callback #{inspect(callback)} failed in hook :#{hook_name}: " <>
                    Exception.message(e)
                )

                Merge.error_sentinel()
            catch
              kind, reason ->
                Logger.error(
                  "Chained callback #{inspect(callback)} crashed in hook :#{hook_name}: " <>
                    Exception.format(kind, reason, __STACKTRACE__)
                )

                Merge.error_sentinel()
            end

          next_args =
            if is_map(result) and result != :callback_failed do
              Enum.reduce(key_to_index, current_args, fn {key, idx}, acc_args ->
                val = resolve_map_key(result, key)

                if val != nil and idx < length(acc_args) do
                  List.replace_at(acc_args, idx, val)
                else
                  acc_args
                end
              end)
            else
              current_args
            end

          {[result | acc], next_args}
        end)

      merge_strategy = Hooks.merge_type(hook_name)
      Merge.merge_results(Enum.reverse(results), merge_strategy)
    end
  end

  @doc """
  Triggers all callbacks registered for the given hook and returns
  the **raw unmerged results list**.

  Unlike `trigger/2`, which merges results according to the hook's
  declared merge strategy, `trigger_raw/2` returns the list of
  individual callback results in registration order — with crashed
  callbacks replaced by `:callback_failed` sentinels.

  This is essential for fail-closed security hooks (e.g.
  `run_shell_command`) where merge semantics can silently discard
  `:callback_failed` sentinels when mixed with `nil` or
  `%{blocked: false}` results.

  Returns `[]` if no callbacks are registered.

  ## Examples

      CodePuppyControl.Callbacks.trigger_raw(:run_shell_command, [context, cmd, cwd])
      #=> [%{blocked: true}, :callback_failed, nil]
  """
  @spec trigger_raw(atom(), [term()]) :: [term()]
  def trigger_raw(hook_name, args \\ []) when is_atom(hook_name) and is_list(args) do
    callbacks = Registry.get_callbacks(hook_name)

    if callbacks == [] do
      []
    else
      execute_callbacks(hook_name, callbacks, args)
    end
  end

  @doc """
  Async variant of `trigger_raw/2` for hooks declared with `async: true`.

  Like `trigger_raw/2`, returns the **unmerged** results list with
  `:callback_failed` sentinels preserved. Unlike `trigger_async/2`,
  which merges results before returning, this function preserves
  raw results for fail-closed security checks.

  Returns `{:ok, [results]}` or `{:error, :not_async}` if the hook
  doesn't support async execution.

  ## Examples

      CodePuppyControl.Callbacks.trigger_raw_async(:file_permission, [ctx, path, op])
      #=> {:ok, [true, :callback_failed, nil]}
  """
  @spec trigger_raw_async(atom(), [term()]) :: {:ok, [term()]} | {:error, :not_async}
  def trigger_raw_async(hook_name, args \\ []) when is_atom(hook_name) and is_list(args) do
    if Hooks.async?(hook_name) do
      callbacks = Registry.get_callbacks(hook_name)

      if callbacks == [] do
        {:ok, []}
      else
        results = execute_callbacks_async(hook_name, callbacks, args)
        {:ok, results}
      end
    else
      {:error, :not_async}
    end
  end

  # ── Python-Compatible Alias ─────────────────────────────────────

  @doc """
  Triggers all callbacks for a hook (alias for `trigger/2`).

  This provides a Python-compatible API matching the `on(hook, args)`
  pattern from `code_puppy.callbacks`.

  ## Examples

      CodePuppyControl.Callbacks.on(:startup)
      CodePuppyControl.Callbacks.on(:custom_command, ["/echo hello", "echo"])
  """
  @spec on(atom(), [term()]) :: term()
  def on(hook_name, args \\ []) when is_atom(hook_name) and is_list(args) do
    trigger(hook_name, args)
  end

  # ── Introspection ───────────────────────────────────────────────

  @doc """
  Returns the number of callbacks registered for a hook.

  Pass `:all` to get the total count across all hooks.

  ## Examples

      CodePuppyControl.Callbacks.count_callbacks(:startup)
      #=> 3

      CodePuppyControl.Callbacks.count_callbacks(:all)
      #=> 12
  """
  @spec count_callbacks(atom()) :: non_neg_integer()
  def count_callbacks(hook_name \\ :all) when is_atom(hook_name) do
    Registry.count(hook_name)
  end

  @doc """
  Returns a list of hook names that have at least one callback registered.
  """
  @spec active_hooks() :: [atom()]
  def active_hooks do
    Registry.active_hooks()
  end

  @doc """
  Returns the ordered list of callbacks for a hook (for debugging).
  """
  @spec get_callbacks(atom()) :: [function()]
  def get_callbacks(hook_name) when is_atom(hook_name) do
    Registry.get_callbacks(hook_name)
  end

  @doc """
  Removes all callbacks for a hook, or all hooks if `:all` is passed.

  Primarily used in test teardown for isolation.
  """
  @spec clear(atom() | nil) :: :ok
  def clear(hook_name \\ nil) do
    Registry.clear(hook_name)
  end

  # ── Private Helpers ─────────────────────────────────────────────

  @spec resolve_map_key(map(), atom() | String.t()) :: term() | nil
  defp resolve_map_key(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, to_string(key))
    end
  end

  defp resolve_map_key(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, val} ->
        val

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  @doc false
  @spec execute_callbacks(atom(), [function()], [term()]) :: [term()]
  defp execute_callbacks(hook_name, callbacks, args) do
    Enum.map(callbacks, fn callback ->
      try do
        apply(callback, args)
      rescue
        e ->
          Logger.error(
            "Callback #{inspect(callback)} failed in hook :#{hook_name}: " <>
              Exception.message(e) <> "\n" <> Exception.format_stacktrace(__STACKTRACE__)
          )

          Merge.error_sentinel()
      catch
        kind, reason ->
          Logger.error(
            "Callback #{inspect(callback)} crashed in hook :#{hook_name}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          Merge.error_sentinel()
      end
    end)
  end

  @doc false
  @spec execute_callbacks_async(atom(), [function()], [term()]) :: [term()]
  defp execute_callbacks_async(hook_name, callbacks, args) do
    # Spawn all callbacks as tasks, preserving registration order in results
    tasks =
      Enum.map(callbacks, fn callback ->
        Task.async(fn ->
          try do
            apply(callback, args)
          rescue
            e ->
              Logger.error(
                "Async callback #{inspect(callback)} failed in hook :#{hook_name}: " <>
                  Exception.message(e)
              )

              Merge.error_sentinel()
          catch
            kind, reason ->
              Logger.error(
                "Async callback #{inspect(callback)} crashed in hook :#{hook_name}: " <>
                  Exception.format(kind, reason, __STACKTRACE__)
              )

              Merge.error_sentinel()
          end
        end)
      end)

    # Await all tasks — order preserved because we zip with callbacks
    Enum.map(tasks, fn task ->
      try do
        Task.await(task, 5_000)
      catch
        :exit, {:timeout, _} ->
          Logger.error("Async callback timed out in hook :#{hook_name}")
          Merge.error_sentinel()

        :exit, {reason, _} ->
          Logger.error("Async callback exited in hook :#{hook_name}: #{inspect(reason)}")
          Merge.error_sentinel()
      end
    end)
  end
end
