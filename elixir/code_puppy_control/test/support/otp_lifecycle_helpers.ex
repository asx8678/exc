defmodule CodePuppyControl.TestSupport.OtpLifecycleHelpers do
  @moduledoc """
  Shared helpers for OTP lifecycle/restart tests.

  Provides process killing, restart waiting, and result collection
  utilities used across multiple OTP lifecycle test modules.
  """

  import ExUnit.Assertions

  @doc """
  Kill a named GenServer process and wait for its :DOWN message.
  """
  @spec kill_process(module()) :: :ok
  def kill_process(module) do
    pid = Process.whereis(module)

    if pid == nil do
      raise "Expected #{inspect(module)} to be running before kill"
    end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
    after
      5000 -> raise "Timeout waiting for process #{inspect(pid)} to die"
    end
  end

  @doc """
  Kill a process and wait for supervisor to restart it, verifying
  the ETS table is also recreated. Returns the new pid.
  """
  @spec kill_and_restart(module(), atom()) :: pid()
  def kill_and_restart(module, ets_table) do
    old_pid = Process.whereis(module)
    kill_process(module)
    new_pid = wait_for_restart(module, ets_table)
    assert new_pid != old_pid, "Expected new PID after restart"
    new_pid
  end

  @doc """
  Wait for a named GenServer to restart and its ETS table to be recreated.
  Polls every 20ms until both conditions are met or timeout expires.
  """
  @spec wait_for_restart(module(), atom(), pos_integer()) :: pid()
  def wait_for_restart(module, ets_table, timeout_ms \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_restart(module, ets_table, deadline)
  end

  @doc """
  Wait for a named GenServer to restart, ETS table to be recreated, AND
  a population check to pass (e.g. configs are loaded).

  `population_fn` is a 0-arity function that should return a truthy value
  once the ETS table is fully populated. Polls every 20ms until all
  conditions are met or timeout expires.

  This exists because `wait_for_restart/3` only checks process + table
  existence, but some GenServers (like ModelRegistry) create the ETS
  table in init/1 *before* populating it — there is a window where the
  table exists but is empty, causing assertions on data to fail.
  """
  @spec wait_for_restart_and_populated(module(), atom(), (-> term()), pos_integer()) ::
          pid()
  def wait_for_restart_and_populated(module, ets_table, population_fn, timeout_ms \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    pid = do_wait_for_restart(module, ets_table, deadline)
    do_wait_for_populated(population_fn, deadline)
    pid
  end

  defp do_wait_for_populated(population_fn, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for ETS table to be populated")
    end

    if population_fn.() do
      :ok
    else
      Process.sleep(20)
      do_wait_for_populated(population_fn, deadline)
    end
  end

  defp do_wait_for_restart(module, ets_table, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for #{inspect(module)} to restart")
    end

    case Process.whereis(module) do
      nil ->
        Process.sleep(20)
        do_wait_for_restart(module, ets_table, deadline)

      pid ->
        if not Process.alive?(pid) do
          Process.sleep(20)
          do_wait_for_restart(module, ets_table, deadline)
        else
          case :ets.whereis(ets_table) do
            :undefined ->
              Process.sleep(20)
              do_wait_for_restart(module, ets_table, deadline)

            _ref ->
              pid
          end
        end
    end
  end

  @doc """
  Flush all {:EXIT, _, _} messages from the test process mailbox.
  """
  @spec flush_exits() :: :ok
  def flush_exits do
    receive do
      {:EXIT, _, _} -> flush_exits()
    after
      0 -> :ok
    end
  end

  @doc """
  Kill the process and wait for its :DOWN message, but do NOT wait for restart.

  **Important:** The supervisor may restart the process at any time after the kill.
  This function does NOT guarantee a stable "dead window" — only that the
  current process instance is dead at the moment of return. Tests should
  accept that calls made after this may hit either the dead process (exit)
  or the newly restarted one (success).
  """
  @spec kill_only(module()) :: :ok
  def kill_only(module) do
    pid = Process.whereis(module)

    if pid == nil do
      raise "Expected #{inspect(module)} to be running before kill"
    end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
    after
      5000 -> raise "Timeout waiting for process #{inspect(pid)} to die"
    end

    :ok
  end

  @doc """
  Yield on many tasks with a timeout, shutting down any that don't finish.

  Returns a list of `{task, result}` tuples like `Task.yield_many/2`, but
  guarantees that timed-out tasks are shut down (preventing leaked processes).
  A `nil` result from `Task.yield_many` is converted to `{:exit, :timeout}`
  so callers can distinguish timeouts from clean results.
  """
  @spec yield_and_collect([Task.t()], timeout()) :: [{Task.t(), term()}]
  def yield_and_collect(tasks, timeout \\ 10_000) do
    tasks
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, result} ->
      case result do
        nil ->
          # Task didn't finish — shut it down to prevent leaks.
          Task.shutdown(task, :brutal_kill)
          {task, {:exit, :timeout}}

        other ->
          {task, other}
      end
    end)
  end

  @doc """
  Collect results from Task.yield_many, classifying each as :ok, :error, or :timeout.
  Returns {successes, errors, timeouts} counts. Accepts a list of acceptable ok values.
  """
  @spec collect_task_results([{Task.t(), term()}], [term()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def collect_task_results(yield_results, ok_values \\ nil) do
    Enum.reduce(yield_results, {0, 0, 0}, fn {_task, result}, {ok, err, tmo} ->
      case classify_result(result, ok_values) do
        :ok -> {ok + 1, err, tmo}
        :error -> {ok, err + 1, tmo}
        :timeout -> {ok, err, tmo + 1}
      end
    end)
  end

  defp classify_result({:ok, val}, nil) when val != nil, do: :ok

  defp classify_result({:ok, val}, ok_values) when is_list(ok_values),
    do: if(val in ok_values, do: :ok, else: :error)

  defp classify_result({:exit, :timeout}, _), do: :timeout
  defp classify_result({:exit, _}, _), do: :error
  defp classify_result(_, _), do: :error

  @doc """
  Spawn N workers that call `fun` repeatedly, then kill the target module mid-flight.
  Workers trap exits and catch errors, so they never crash.
  Returns {success_count, error_count} from all worker invocations.
  Only non-nil, non-exit results count as successes.
  """
  @spec spawn_workers_and_kill(pos_integer(), pos_integer(), module(), (-> term())) ::
          {non_neg_integer(), non_neg_integer()}
  def spawn_workers_and_kill(worker_count, iterations, target_module, fun) do
    caller = self()
    success_count = :atomics.new(1, [])
    error_count = :atomics.new(1, [])

    for _i <- 1..worker_count do
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        for _j <- 1..iterations do
          try do
            case fun.() do
              nil -> :atomics.add(error_count, 1, 1)
              _ -> :atomics.add(success_count, 1, 1)
            end
          catch
            :exit, _ -> :atomics.add(error_count, 1, 1)
            _, _ -> :atomics.add(error_count, 1, 1)
          end

          Process.sleep(:rand.uniform(5))
        end

        send(caller, :worker_done)
      end)
    end

    # Kill mid-flight after a small delay
    Process.sleep(10)
    kill_only(target_module)

    # Wait for all workers to finish
    for _ <- 1..worker_count do
      receive do
        :worker_done -> :ok
      after
        10_000 -> flunk("Worker didn't finish in time")
      end
    end

    {:atomics.get(success_count, 1), :atomics.get(error_count, 1)}
  end
end
