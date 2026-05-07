defmodule CodePuppyControl.Runtime.Snapshot do
  @moduledoc """
  Live snapshot of BEAM runtime state for monitoring and IEx introspection.

  Returns a map with processes, ports, memory, scheduler, supervisor
  population, concurrency-limiter, and rate-limiter state. Shared by
  the `/health/runtime` HTTP endpoint and the `print/0` IEx helper.

  ## Usage

      iex> CodePuppyControl.Runtime.Snapshot.snapshot()
      %{processes: %{current: 42, limit: 262144}, ...}

      iex> CodePuppyControl.Runtime.Snapshot.print()
      :ok
  """

  alias CodePuppyControl.Runtime.Limits

  # ── Public API ──────────────────────────────────────────────────────────

  @type sup_entry :: %{
          current: non_neg_integer(),
          max: non_neg_integer(),
          utilization: float()
        }

  @type snapshot :: %{
          processes: %{current: non_neg_integer(), limit: non_neg_integer()},
          ports: %{current: non_neg_integer(), limit: non_neg_integer()},
          memory_mb: map(),
          schedulers: map(),
          supervisors: %{
            mcp_servers: sup_entry(),
            mcp_clients: sup_entry(),
            runs: sup_entry(),
            executors: sup_entry(),
            agent_states: sup_entry()
          },
          limits: map(),
          concurrency: map(),
          rate_limiter: map()
        }

  @doc """
  Returns a map with a live snapshot of BEAM runtime state.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    %{
      processes: %{
        current: :erlang.system_info(:process_count),
        limit: :erlang.system_info(:process_limit)
      },
      ports: %{
        current: :erlang.system_info(:port_count),
        limit: :erlang.system_info(:port_limit)
      },
      memory_mb: memory_snapshot(),
      schedulers: %{
        online: System.schedulers_online(),
        total: System.schedulers(),
        dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers),
        dirty_io: :erlang.system_info(:dirty_io_schedulers)
      },
      supervisors: supervisor_snapshot(),
      limits: Limits.all(),
      concurrency: concurrency_snapshot(),
      rate_limiter: rate_limiter_snapshot()
    }
  end

  @doc """
  Pretty-prints the runtime snapshot to stdout. Designed for IEx sessions.
  """
  @spec print() :: :ok
  def print do
    snap = snapshot()

    IO.puts("=== Code Puppy Runtime Snapshot ===\n")

    IO.puts("Processes: #{snap.processes.current} / #{snap.processes.limit}")
    IO.puts("Ports:     #{snap.ports.current} / #{snap.ports.limit}")
    IO.puts("")

    IO.puts("Memory (MB):")

    for {k, v} <- snap.memory_mb do
      IO.puts("  #{k}: #{v}")
    end

    IO.puts("")

    IO.puts("Supervisors:")

    for {k, %{current: c, max: m, utilization: u}} <- snap.supervisors do
      IO.puts("  #{k}: #{c} / #{m}  (#{u}%)")
    end

    :ok
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp memory_snapshot do
    mem = :erlang.memory()

    %{
      total: to_mb(mem[:total]),
      processes: to_mb(mem[:processes]),
      ets: to_mb(mem[:ets]),
      binary: to_mb(mem[:binary]),
      code: to_mb(mem[:code]),
      atom: to_mb(mem[:atom])
    }
  end

  defp to_mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp supervisor_snapshot do
    %{
      mcp_servers: sup_entry(CodePuppyControl.MCP.Supervisor, Limits.max_mcp_servers()),
      mcp_clients: sup_entry(CodePuppyControl.MCP.ClientSupervisor, Limits.max_mcp_clients()),
      runs: sup_entry(CodePuppyControl.Run.Supervisor, Limits.max_runs()),
      executors: sup_entry(CodePuppyControl.Run.Executor.Supervisor, Limits.max_runs()),
      agent_states: sup_entry(CodePuppyControl.Agent.State.Supervisor, Limits.max_agent_states())
    }
  end

  defp sup_entry(mod, max) do
    current =
      case Process.whereis(mod) do
        nil -> 0
        _pid -> DynamicSupervisor.count_children(mod).workers
      end

    %{current: current, max: max, utilization: pct(current, max)}
  end

  defp pct(_current, 0), do: 0.0
  defp pct(current, max), do: Float.round(current / max * 100, 1)

  defp concurrency_snapshot do
    try do
      CodePuppyControl.Concurrency.Limiter.status()
    rescue
      _ -> %{}
    end
  end

  defp rate_limiter_snapshot do
    try do
      if function_exported?(CodePuppyControl.RateLimiter.Adaptive, :table, 0) do
        table = CodePuppyControl.RateLimiter.Adaptive.table()

        case :ets.info(table) do
          :undefined ->
            %{}

          _ ->
            table
            |> :ets.tab2list()
            |> Enum.map(fn
              {model_name, _state, _opened, _mult, _consec, ratio, _last, total} ->
                {model_name, %{capacity_ratio: ratio, total_429s: total}}

              _ ->
                nil
            end)
            |> Enum.reject(&is_nil/1)
            |> Map.new()
        end
      else
        %{}
      end
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
