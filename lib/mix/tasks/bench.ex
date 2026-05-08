defmodule Mix.Tasks.Bench do
  @moduledoc """
  Benchmark the native Elixir control plane runtime.

  This task measures core Elixir runtime primitives used by the
  CodePuppy control plane — no Python bridge or external worker scripts
  required.

  Benchmarks:
  1. GenServer spawn latency — time to start a supervised process
  2. GenServer call latency — round-trip `call` time
  3. Concurrent Task scaling — throughput with 1–16 concurrent tasks
  4. Supervisor fault recovery — time to detect crash and restart

  ## Usage

      mix bench                    # Run full benchmark suite
      mix bench --quick            # Run with reduced iterations

  ## Output

  Results are printed to stdout as JSON.
  """

  use Mix.Task

  require Logger

  @shortdoc "Benchmark native Elixir control plane runtime"

  # Default iteration counts
  @default_spawn_iterations 10
  @default_call_iterations 100
  @default_concurrent_workers [1, 2, 4, 8, 16]
  @default_requests_per_worker 10

  # Quick mode iteration counts
  @quick_spawn_iterations 3
  @quick_call_iterations 20
  @quick_concurrent_workers [1, 2, 4]
  @quick_requests_per_worker 5

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [quick: :boolean])
    quick_mode = Keyword.get(opts, :quick, false)

    ensure_application_started()

    iterations = get_iterations(quick_mode)
    results = %{}

    # 1. GenServer Spawn Latency
    Mix.shell().info("Running GenServer spawn latency benchmark...")
    spawn_results = benchmark_spawn_latency(iterations.spawn)
    results = Map.put(results, :spawn_latency, spawn_results)

    # 2. GenServer Call Latency
    Mix.shell().info("Running GenServer call latency benchmark...")
    call_results = benchmark_call_latency(iterations.call)
    results = Map.put(results, :call_latency, call_results)

    # 3. Concurrent Task Scaling
    Mix.shell().info("Running concurrent Task scaling benchmark...")

    scaling_results =
      benchmark_concurrent_scaling(
        iterations.concurrent_workers,
        iterations.requests_per_worker
      )

    results = Map.put(results, :concurrent_scaling, scaling_results)

    # 4. Supervisor Fault Recovery
    Mix.shell().info("Running supervisor fault recovery benchmark...")
    fault_results = benchmark_fault_recovery()
    results = Map.put(results, :fault_recovery, fault_results)

    # Add metadata
    results =
      Map.put(results, :metadata, %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        mode: if(quick_mode, do: "quick", else: "full"),
        iterations: iterations,
        elixir_version: System.version(),
        otp_version: :erlang.system_info(:otp_release) |> to_string()
      })

    json_output = Jason.encode!(results, pretty: true)
    IO.puts(json_output)

    :ok
  end

  # --- Benchmark Functions ---

  defp benchmark_spawn_latency(count) do
    # Use a temporary supervisor to spawn/cleanup bench workers
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    latencies =
      for i <- 1..count do
        {time_us, {:ok, _pid}} =
          :timer.tc(fn ->
            DynamicSupervisor.start_child(sup, {BenchEchoWorker, i})
          end)

        time_us
      end

    # Cleanup
    DynamicSupervisor.stop(sup)

    %{
      iterations: count,
      mean_us: mean(latencies),
      median_us: median(latencies),
      p95_us: percentile(latencies, 95),
      min_us: Enum.min(latencies),
      max_us: Enum.max(latencies),
      raw_times: latencies
    }
  end

  defp benchmark_call_latency(count) do
    # Start a single worker
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, pid} = DynamicSupervisor.start_child(sup, {BenchEchoWorker, 0})

    # Warmup
    for _ <- 1..5 do
      GenServer.call(pid, {:echo, "warmup"}, 5000)
    end

    # Benchmark
    latencies =
      for i <- 1..count do
        message = "test-#{i}"

        {time_us, ^message} =
          :timer.tc(fn ->
            GenServer.call(pid, {:echo, message}, 5000)
          end)

        time_us
      end

    # Cleanup
    DynamicSupervisor.stop(sup)

    %{
      iterations: count,
      errors: 0,
      mean_us: mean(latencies),
      median_us: median(latencies),
      p95_us: percentile(latencies, 95),
      min_us: Enum.min(latencies),
      max_us: Enum.max(latencies),
      raw_times: latencies
    }
  end

  defp benchmark_concurrent_scaling(worker_counts, requests_per_worker) do
    Enum.map(worker_counts, fn num_workers ->
      Mix.shell().info("  Testing with #{num_workers} concurrent tasks...")

      # Start workers under a shared supervisor
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      start_time = System.monotonic_time(:microsecond)

      started_workers =
        for i <- 1..num_workers do
          {:ok, pid} = DynamicSupervisor.start_child(sup, {BenchEchoWorker, i})
          pid
        end

      spawn_time_us = System.monotonic_time(:microsecond) - start_time

      # Send requests concurrently via Task
      request_tasks =
        for {pid, idx} <- Enum.with_index(started_workers),
            req_idx <- 1..requests_per_worker do
          Task.async(fn ->
            message = "req-#{req_idx}"

            {time_us, ^message} =
              :timer.tc(fn ->
                GenServer.call(pid, {:echo, message}, 5000)
              end)

            {idx, req_idx, time_us}
          end)
        end

      results = Task.await_many(request_tasks, 30_000)
      end_time = System.monotonic_time(:microsecond)

      total_time_us = end_time - start_time
      total_requests = num_workers * requests_per_worker

      # Per-worker stats
      worker_latencies =
        Enum.group_by(results, fn {idx, _, _} -> idx end, fn {_, _, time_us} ->
          time_us
        end)

      per_worker_stats =
        Map.new(worker_latencies, fn {idx, times} ->
          {idx,
           %{
             mean_us: mean(times),
             median_us: median(times),
             min_us: Enum.min(times),
             max_us: Enum.max(times)
           }}
        end)

      # Cleanup
      DynamicSupervisor.stop(sup)

      %{
        num_workers: num_workers,
        requests_per_worker: requests_per_worker,
        total_requests: total_requests,
        total_time_us: total_time_us,
        spawn_time_us: spawn_time_us,
        throughput_rps: throughput(total_requests, total_time_us),
        errors: 0,
        mean_us: mean(Enum.map(results, fn {_, _, t} -> t end)),
        median_us: median(Enum.map(results, fn {_, _, t} -> t end)),
        p95_us: percentile(Enum.map(results, fn {_, _, t} -> t end), 95),
        per_worker_stats: per_worker_stats
      }
    end)
  end

  defp benchmark_fault_recovery do
    # Start a supervised worker
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, max_restarts: 10)
    {:ok, pid} = DynamicSupervisor.start_child(sup, {BenchEchoWorker, 0})
    ref = Process.monitor(pid)

    # Kill the process
    kill_time = System.monotonic_time(:microsecond)
    Process.exit(pid, :kill)

    # Wait for the DOWN message
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5000 -> :timeout
    end

    detection_time_us = System.monotonic_time(:microsecond) - kill_time

    # Verify worker pid is gone and supervisor is still alive
    Process.sleep(10)

    result = %{
      detection_time_us: detection_time_us,
      worker_gone: not Process.alive?(pid),
      supervisor_alive: Process.alive?(sup)
    }

    # Cleanup
    if Process.alive?(sup), do: DynamicSupervisor.stop(sup)

    result
  end

  # --- Helper Functions ---

  defp get_iterations(quick_mode) do
    if quick_mode do
      %{
        spawn: @quick_spawn_iterations,
        call: @quick_call_iterations,
        concurrent_workers: @quick_concurrent_workers,
        requests_per_worker: @quick_requests_per_worker
      }
    else
      %{
        spawn: @default_spawn_iterations,
        call: @default_call_iterations,
        concurrent_workers: @default_concurrent_workers,
        requests_per_worker: @default_requests_per_worker
      }
    end
  end

  defp ensure_application_started do
    case Application.ensure_all_started(:code_puppy_control) do
      {:ok, _} ->
        :ok

      {:error, {app, reason}} ->
        if app == :code_puppy_control do
          Mix.shell().error("Failed to start application: #{inspect(reason)}")
          exit({:shutdown, 1})
        else
          :ok
        end
    end

    Process.sleep(100)
  end

  # --- Statistics Functions ---

  defp mean([]), do: 0
  defp mean(list), do: Enum.sum(list) / length(list)

  defp median(list) when length(list) == 0, do: 0

  defp median(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  defp percentile([], _p), do: 0

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    index = p / 100 * (length(sorted) - 1)
    lower = floor(index)
    upper = ceil(index)

    if lower == upper do
      Enum.at(sorted, lower)
    else
      weight = index - lower
      lower_val = Enum.at(sorted, lower)
      upper_val = Enum.at(sorted, upper)
      lower_val + weight * (upper_val - lower_val)
    end
  end

  defp throughput(requests, time_us) when time_us > 0 do
    requests / (time_us / 1_000_000)
  end

  defp throughput(_, _), do: 0
end

# --- Internal Benchmark Worker ---

defmodule BenchEchoWorker do
  @moduledoc false
  use GenServer

  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  @impl true
  def init(_id) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:echo, message}, _from, state) do
    {:reply, message, state}
  end
end
