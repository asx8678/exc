defmodule Mix.Tasks.Bench do
  @moduledoc """
  Benchmark Python worker management in the CodePuppy control plane.

  > **Bridge-mode compat only.** This task benchmarks the Python bridge
  > (`PythonWorker.Port`), which is only active under `PUP_RUNTIME=python`
  > / `--bridge-mode`. The default native Burrito runtime does not use
  > PythonWorker. Native Elixir performance is measured via standard
  > `mix test` and `Benchee` benchmarks, not this task.

  This task measures:
  1. Worker spawn latency (time to initialize)
  2. Request/response latency (echo round-trip)
  3. Concurrent worker scaling (1-16 workers)
  4. Fault recovery (crash detection time)

  ## Usage

      mix bench                    # Run full benchmark suite
      mix bench --quick            # Run with reduced iterations

  ## Output

  Results are printed to stdout as JSON for comparison with Python benchmarks.

  ## Prerequisites

  The benchmark requires the Python bench worker script at:
    ../../scripts/bench_worker.py (relative to elixir/code_puppy_control)

  The task will automatically start the application if not already running.
  """

  use Mix.Task

  require Logger

  alias CodePuppyControl.PythonWorker.Supervisor, as: WorkerSupervisor
  alias CodePuppyControl.PythonWorker.Port

  @shortdoc "Benchmark Python bridge worker (compat/bridge-mode only)"

  # Default iteration counts
  @default_spawn_iterations 10
  @default_echo_iterations 100
  @default_concurrent_workers [1, 2, 4, 8, 16]
  @default_requests_per_worker 10

  # Quick mode iteration counts
  @quick_spawn_iterations 3
  @quick_echo_iterations 20
  @quick_concurrent_workers [1, 2, 4]
  @quick_requests_per_worker 5

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [quick: :boolean])
    quick_mode = Keyword.get(opts, :quick, false)

    # Check for bench worker script
    script_path = get_script_path()

    unless File.exists?(script_path) do
      Mix.shell().error("Bench worker script not found: #{script_path}")
      Mix.shell().error("Expected path: ../../scripts/bench_worker.py")
      Mix.shell().error("\nPlease ensure the Python bench worker script exists.")
      exit({:shutdown, 1})
    end

    # Start the application (required for supervision tree)
    ensure_application_started()

    # Run benchmarks
    iterations = get_iterations(quick_mode)
    results = %{}

    # 1. Worker Spawn Latency
    Mix.shell().info("Running worker spawn latency benchmark...")
    spawn_results = benchmark_spawn_latency(iterations.spawn, script_path)
    results = Map.put(results, :spawn_latency, spawn_results)

    # 2. Request/Response Latency
    Mix.shell().info("Running request/response latency benchmark...")
    echo_results = benchmark_echo_latency(iterations.echo, script_path)
    results = Map.put(results, :echo_latency, echo_results)

    # 3. Concurrent Worker Scaling
    Mix.shell().info("Running concurrent worker scaling benchmark...")

    scaling_results =
      benchmark_concurrent_scaling(
        iterations.concurrent_workers,
        iterations.requests_per_worker,
        script_path
      )

    results = Map.put(results, :concurrent_scaling, scaling_results)

    # 4. Fault Recovery
    Mix.shell().info("Running fault recovery benchmark...")
    fault_results = benchmark_fault_recovery(script_path)
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

    # Output JSON results
    json_output = Jason.encode!(results, pretty: true)
    IO.puts(json_output)

    :ok
  end

  # --- Benchmark Functions ---

  defp benchmark_spawn_latency(count, script_path) do
    latencies =
      for i <- 1..count do
        run_id = "bench-spawn-#{i}-#{System.unique_integer([:positive])}"

        # Measure time from start_worker to ping response
        {time_us, _} =
          :timer.tc(fn ->
            # Start the worker
            {:ok, pid} = WorkerSupervisor.start_worker(run_id, script_path: script_path)

            # Wait for it to be ready by sending a ping
            :ok = wait_for_worker_ready(run_id, 5000)

            pid
          end)

        # Cleanup
        WorkerSupervisor.terminate_worker(run_id)

        time_us
      end

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

  defp benchmark_echo_latency(count, script_path) do
    run_id = "bench-echo-#{System.unique_integer([:positive])}"

    # Start worker
    {:ok, _} = WorkerSupervisor.start_worker(run_id, script_path: script_path)
    :ok = wait_for_worker_ready(run_id, 5000)

    # Warmup
    for _ <- 1..5 do
      Port.call(run_id, "echo", %{"message" => "warmup"}, 5000)
    end

    # Benchmark
    latencies =
      for i <- 1..count do
        message = "test-#{i}"

        {time_us, result} =
          :timer.tc(fn ->
            Port.call(run_id, "echo", %{"message" => message}, 5000)
          end)

        # Verify response
        case result do
          {:ok, response} ->
            if response["echo"] == message do
              time_us
            else
              :error
            end

          _ ->
            :error
        end
      end

    # Cleanup
    WorkerSupervisor.terminate_worker(run_id)

    # Filter out errors
    valid_latencies = Enum.reject(latencies, &(&1 == :error))
    errors = Enum.count(latencies, &(&1 == :error))

    %{
      iterations: count,
      errors: errors,
      mean_us: mean(valid_latencies),
      median_us: median(valid_latencies),
      p95_us: percentile(valid_latencies, 95),
      min_us: if(valid_latencies != [], do: Enum.min(valid_latencies), else: nil),
      max_us: if(valid_latencies != [], do: Enum.max(valid_latencies), else: nil),
      raw_times: valid_latencies
    }
  end

  defp benchmark_concurrent_scaling(worker_counts, requests_per_worker, script_path) do
    Enum.map(worker_counts, fn num_workers ->
      Mix.shell().info("  Testing with #{num_workers} workers...")

      # Start workers concurrently
      workers =
        for i <- 1..num_workers do
          run_id = "bench-scale-#{num_workers}-#{i}-#{System.unique_integer([:positive])}"
          {run_id, i}
        end

      # Spawn all workers
      start_time = System.monotonic_time(:microsecond)

      started_workers =
        Enum.map(workers, fn {run_id, idx} ->
          {:ok, pid} = WorkerSupervisor.start_worker(run_id, script_path: script_path)
          {run_id, idx, pid}
        end)

      # Wait for all to be ready
      Enum.each(started_workers, fn {run_id, _, _} ->
        :ok = wait_for_worker_ready(run_id, 5000)
      end)

      spawn_time_us = System.monotonic_time(:microsecond) - start_time

      # Send requests to all workers concurrently
      request_tasks =
        for {run_id, idx, _} <- started_workers,
            req_idx <- 1..requests_per_worker do
          Task.async(fn ->
            {time_us, result} =
              :timer.tc(fn ->
                Port.call(run_id, "echo", %{"message" => "req-#{req_idx}"}, 5000)
              end)

            {idx, req_idx, time_us, result}
          end)
        end

      # Collect all results
      results = Task.await_many(request_tasks, 30_000)
      end_time = System.monotonic_time(:microsecond)

      total_time_us = end_time - start_time
      total_requests = num_workers * requests_per_worker

      # Calculate per-worker stats
      worker_latencies =
        Enum.group_by(results, fn {idx, _, _, _} -> idx end, fn {_, _, time_us, _} ->
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

      # Calculate errors
      errors = Enum.count(results, fn {_, _, _, result} -> match?({:error, _}, result) end)

      # Cleanup
      Enum.each(started_workers, fn {run_id, _, _} ->
        WorkerSupervisor.terminate_worker(run_id)
      end)

      %{
        num_workers: num_workers,
        requests_per_worker: requests_per_worker,
        total_requests: total_requests,
        total_time_us: total_time_us,
        spawn_time_us: spawn_time_us,
        throughput_rps: throughput(total_requests, total_time_us),
        errors: errors,
        mean_us: mean(Enum.map(results, fn {_, _, t, _} -> t end)),
        median_us: median(Enum.map(results, fn {_, _, t, _} -> t end)),
        p95_us: percentile(Enum.map(results, fn {_, _, t, _} -> t end), 95),
        per_worker_stats: per_worker_stats
      }
    end)
  end

  defp benchmark_fault_recovery(script_path) do
    run_id = "bench-fault-#{System.unique_integer([:positive])}"

    # Start worker
    {:ok, pid} = WorkerSupervisor.start_worker(run_id, script_path: script_path)
    :ok = wait_for_worker_ready(run_id, 5000)

    # Get initial worker count
    initial_count = WorkerSupervisor.worker_count()

    # Kill the worker process
    kill_time = System.monotonic_time(:microsecond)
    Process.exit(pid, :kill)

    # Wait for supervisor to detect and remove worker
    # Poll until worker count changes or timeout
    detection_time =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        Process.sleep(10)
        current_count = WorkerSupervisor.worker_count()

        if current_count < initial_count do
          {:halt, System.monotonic_time(:microsecond)}
        else
          {:cont, nil}
        end
      end)

    detection_time_us =
      if detection_time do
        detection_time - kill_time
      else
        nil
      end

    # Give supervisor time to clean up
    Process.sleep(100)

    # Verify worker is no longer in list
    workers = WorkerSupervisor.list_workers()
    worker_gone = not Enum.any?(workers, fn {id, _} -> id == run_id end)

    %{
      detection_time_us: detection_time_us,
      worker_gone: worker_gone,
      initial_count: initial_count,
      final_count: WorkerSupervisor.worker_count()
    }
  end

  # --- Helper Functions ---

  defp get_script_path do
    # From lib/mix/tasks/, go up 3 levels to reach elixir/code_puppy_control/
    Path.expand("../../../scripts/bench_worker.py", __DIR__)
  end

  defp get_iterations(quick_mode) do
    if quick_mode do
      %{
        spawn: @quick_spawn_iterations,
        echo: @quick_echo_iterations,
        concurrent_workers: @quick_concurrent_workers,
        requests_per_worker: @quick_requests_per_worker
      }
    else
      %{
        spawn: @default_spawn_iterations,
        echo: @default_echo_iterations,
        concurrent_workers: @default_concurrent_workers,
        requests_per_worker: @default_requests_per_worker
      }
    end
  end

  defp ensure_application_started do
    # Start the application supervision tree
    case Application.ensure_all_started(:code_puppy_control) do
      {:ok, _} ->
        :ok

      {:error, {app, reason}} ->
        # Some dependencies might already be started
        if app == :code_puppy_control do
          Mix.shell().error("Failed to start application: #{inspect(reason)}")
          exit({:shutdown, 1})
        else
          # Try to continue - the important processes might still be running
          :ok
        end
    end

    # Give processes time to initialize
    Process.sleep(100)
  end

  defp wait_for_worker_ready(run_id, timeout_ms) do
    # Try to ping the worker until it responds or timeout
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_loop(run_id, deadline)
  end

  defp wait_loop(run_id, deadline) do
    case Port.call(run_id, "ping", %{}, 1000) do
      {:ok, _} ->
        :ok

      _ ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(10)
          wait_loop(run_id, deadline)
        else
          {:error, :timeout}
        end
    end
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
