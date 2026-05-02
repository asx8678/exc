#!/usr/bin/env python3
"""
Elixir Control Plane vs Python-Only Benchmark Suite

This benchmark compares two approaches for managing Python workers:

1. Elixir Control Plane (simulated):
   - Subprocess spawning via Popen (simulating Erlang Ports)
   - JSON-RPC communication with Content-Length framing
   - Pipe-based I/O

2. Python-Only:
   - Direct function calls
   - Asyncio-based concurrency
   - Python subprocess management

Benchmarks:
    1. Spawn Latency - Time to spawn and get "ready" response
    2. Request/Response Latency - Single round-trip time
    3. Throughput Under Load - 100 operations as fast as possible
    4. Concurrent Workers - 1, 2, 4, 8, 16 workers
    5. Fault Recovery - Time to detect failure and respawn

Usage:
    python bench_elixir_vs_python.py
    python bench_elixir_vs_python.py --quick  # CI mode (fewer iterations)
    python bench_elixir_vs_python.py --output results.json
    python bench_elixir_vs_python.py --benchmarks spawn,latency,throughput  # Selective

Output:
    JSON with latency percentiles (mean, median, p95, p99), throughput metrics,
    and comparisons between approaches.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Optional

# ============================================================================
# Configuration
# ============================================================================

WORKER_SCRIPT = Path(__file__).parent / "bench_worker.py"
DEFAULT_WARMUP_RUNS = 3
DEFAULT_BENCHMARK_RUNS = 100
QUICK_WARMUP_RUNS = 1
QUICK_BENCHMARK_RUNS = 20


class BenchmarkMode(Enum):
    """Benchmark execution modes."""

    FULL = "full"
    QUICK = "quick"


@dataclass
class LatencyStats:
    """Statistical summary of latency measurements."""

    mean_ms: float
    median_ms: float
    min_ms: float
    max_ms: float
    p95_ms: float
    p99_ms: float
    stdev_ms: float
    samples: int

    @classmethod
    def from_ns_samples(cls, samples_ns: list[int]) -> "LatencyStats":
        """Calculate stats from nanosecond samples."""
        if not samples_ns:
            return cls(0, 0, 0, 0, 0, 0, 0, 0)

        # Convert to milliseconds
        samples_ms = [ns / 1_000_000 for ns in samples_ns]
        samples_ms.sort()

        n = len(samples_ms)
        mean = statistics.mean(samples_ms)
        median = statistics.median(samples_ms)
        p95_idx = int(n * 0.95) - 1
        p99_idx = int(n * 0.99) - 1

        return cls(
            mean_ms=mean,
            median_ms=median,
            min_ms=min(samples_ms),
            max_ms=max(samples_ms),
            p95_ms=samples_ms[max(0, p95_idx)],
            p99_ms=samples_ms[max(0, p99_idx)],
            stdev_ms=statistics.stdev(samples_ms) if n > 1 else 0.0,
            samples=n,
        )


@dataclass
class ThroughputResult:
    """Throughput benchmark results."""

    total_ops: int
    total_time_ms: float
    ops_per_sec: float
    latency_per_op_ms: LatencyStats


@dataclass
class ConcurrentResult:
    """Concurrent worker benchmark results."""

    num_workers: int
    ops_per_worker: int
    total_ops: int
    total_time_ms: float
    ops_per_sec: float
    per_worker_latency_ms: LatencyStats


@dataclass
class FaultRecoveryResult:
    """Fault recovery benchmark results."""

    detection_time_ms: float
    respawn_time_ms: float
    total_recovery_ms: float


@dataclass
class BenchmarkResult:
    """Complete benchmark results for one approach."""

    approach: str
    timestamp: str
    mode: str

    # Benchmark results
    spawn_latency: LatencyStats = field(
        default_factory=lambda: LatencyStats(0, 0, 0, 0, 0, 0, 0, 0)
    )
    request_latency: LatencyStats = field(
        default_factory=lambda: LatencyStats(0, 0, 0, 0, 0, 0, 0, 0)
    )
    throughput: Optional[ThroughputResult] = None
    concurrent: list[ConcurrentResult] = field(default_factory=list)
    fault_recovery: Optional[FaultRecoveryResult] = None


# ============================================================================
# JSON-RPC Communication Utilities
# ============================================================================


def encode_jsonrpc_frame(msg: dict[str, Any]) -> bytes:
    """
    Encode a JSON-RPC message with Content-Length framing.

    Format:
        Content-Length: <bytes>\r\n\r\n<json body>
    """
    body = json.dumps(msg, separators=(",", ":"), ensure_ascii=False)
    body_bytes = body.encode("utf-8")
    return f"Content-Length: {len(body_bytes)}\r\n\r\n".encode("utf-8") + body_bytes


def read_jsonrpc_frame(pipe) -> Optional[dict[str, Any]]:
    """
    Read a JSON-RPC message from a pipe with Content-Length framing.

    Args:
        pipe: A file-like object with readline and read methods

    Returns:
        Parsed JSON-RPC message or None on EOF/error
    """
    # Read Content-Length header
    line = pipe.readline()
    if not line:
        return None

    # Skip empty lines
    while line and line.strip() == b"":
        line = pipe.readline()

    if not line.startswith(b"Content-Length:"):
        return None

    try:
        length = int(line.split(b":", 1)[1].strip())
    except ValueError, IndexError:
        return None

    # Read separator
    pipe.readline()

    # Read body
    body_bytes = pipe.read(length)
    if len(body_bytes) < length:
        return None

    try:
        return json.loads(body_bytes.decode("utf-8"))
    except json.JSONDecodeError, UnicodeDecodeError:
        return None


class JsonRpcWorker:
    """JSON-RPC worker wrapper with Content-Length framing."""

    def __init__(self, process: subprocess.Popen):
        self.process = process
        self.request_id = 0

    def _next_id(self) -> int:
        self.request_id += 1
        return self.request_id

    def call(
        self, method: str, params: dict[str, Any] = None, timeout: float = 30.0
    ) -> dict[str, Any]:
        """
        Make a synchronous JSON-RPC call.

        Args:
            method: The method name
            params: Method parameters
            timeout: Maximum time to wait for response

        Returns:
            The result dict from the response

        Raises:
            TimeoutError: If no response received in time
            RuntimeError: If error response received
        """
        msg = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params or {},
        }

        frame = encode_jsonrpc_frame(msg)
        self.process.stdin.write(frame)
        self.process.stdin.flush()

        # Read response with timeout
        start = time.perf_counter()
        while (time.perf_counter() - start) < timeout:
            response = read_jsonrpc_frame(self.process.stdout)
            if response is None:
                time.sleep(0.001)
                continue

            # Check if this is our response
            if response.get("id") == msg["id"]:
                if "error" in response:
                    raise RuntimeError(f"RPC error: {response['error']}")
                return response.get("result", {})

            # Could be a notification, continue waiting

        raise TimeoutError(f"No response received within {timeout}s")

    def notify(self, method: str, params: dict[str, Any] = None) -> None:
        """Send a notification (no response expected)."""
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        frame = encode_jsonrpc_frame(msg)
        self.process.stdin.write(frame)
        self.process.stdin.flush()

    def is_alive(self) -> bool:
        """Check if the worker process is still running."""
        return self.process.poll() is None

    def terminate(self) -> None:
        """Terminate the worker process."""
        try:
            self.process.terminate()
            self.process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def kill(self) -> None:
        """Force kill the worker process."""
        self.process.kill()
        self.process.wait()


def spawn_jsonrpc_worker() -> JsonRpcWorker:
    """Spawn a new JSON-RPC worker subprocess."""
    process = subprocess.Popen(
        [sys.executable, str(WORKER_SCRIPT)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,  # Unbuffered for latency
    )
    return JsonRpcWorker(process)


# ============================================================================
# Benchmark Implementations
# ============================================================================


class ElixirControlPlaneBenchmark:
    """Simulates Elixir Control Plane approach with JSON-RPC over pipes."""

    name = "elixir_control_plane"

    def __init__(self, mode: BenchmarkMode):
        self.mode = mode
        self.warmup_runs = (
            QUICK_WARMUP_RUNS if mode == BenchmarkMode.QUICK else DEFAULT_WARMUP_RUNS
        )
        self.runs = (
            QUICK_BENCHMARK_RUNS
            if mode == BenchmarkMode.QUICK
            else DEFAULT_BENCHMARK_RUNS
        )

    def benchmark_spawn_latency(self) -> LatencyStats:
        """Measure time to spawn a worker and get 'ready' response."""
        latencies_ns: list[int] = []

        # Warmup
        for _ in range(self.warmup_runs):
            worker = spawn_jsonrpc_worker()
            worker.call("initialize", {}, timeout=5.0)
            worker.terminate()

        # Benchmark
        for _ in range(self.runs):
            start = time.perf_counter_ns()
            worker = spawn_jsonrpc_worker()
            worker.call("initialize", {}, timeout=5.0)
            end = time.perf_counter_ns()
            latencies_ns.append(end - start)
            worker.terminate()

        return LatencyStats.from_ns_samples(latencies_ns)

    def benchmark_request_latency(self) -> LatencyStats:
        """Measure single request-response latency."""
        latencies_ns: list[int] = []
        worker = spawn_jsonrpc_worker()
        worker.call("initialize", {}, timeout=5.0)

        # Warmup
        for _ in range(self.warmup_runs):
            worker.call("echo", {"msg": "warmup"})

        # Benchmark
        for _ in range(self.runs):
            start = time.perf_counter_ns()
            worker.call("echo", {"msg": "benchmark"})
            end = time.perf_counter_ns()
            latencies_ns.append(end - start)

        worker.terminate()
        return LatencyStats.from_ns_samples(latencies_ns)

    def benchmark_throughput(self) -> ThroughputResult:
        """Measure throughput under load."""
        worker = spawn_jsonrpc_worker()
        worker.call("initialize", {}, timeout=5.0)

        total_ops = 100 if self.mode == BenchmarkMode.QUICK else 1000
        latencies_ns: list[int] = []

        start = time.perf_counter_ns()
        for i in range(total_ops):
            op_start = time.perf_counter_ns()
            worker.call("echo", {"seq": i})
            op_end = time.perf_counter_ns()
            latencies_ns.append(op_end - op_start)
        end = time.perf_counter_ns()

        total_time_ms = (end - start) / 1_000_000

        worker.terminate()

        return ThroughputResult(
            total_ops=total_ops,
            total_time_ms=total_time_ms,
            ops_per_sec=total_ops / (total_time_ms / 1000),
            latency_per_op_ms=LatencyStats.from_ns_samples(latencies_ns),
        )

    def benchmark_concurrent(self) -> list[ConcurrentResult]:
        """Measure performance with concurrent workers."""
        worker_counts = (
            [1, 2, 4, 8, 16] if self.mode == BenchmarkMode.FULL else [1, 4, 8]
        )
        ops_per_worker = 25 if self.mode == BenchmarkMode.QUICK else 100
        results: list[ConcurrentResult] = []

        for num_workers in worker_counts:
            # Spawn workers
            workers: list[JsonRpcWorker] = []
            for _ in range(num_workers):
                w = spawn_jsonrpc_worker()
                w.call("initialize", {}, timeout=5.0)
                workers.append(w)

            # Benchmark
            latencies_ns: list[int] = []
            start = time.perf_counter_ns()

            with ThreadPoolExecutor(max_workers=num_workers) as executor:

                def worker_task(worker: JsonRpcWorker) -> list[int]:
                    worker_latencies: list[int] = []
                    for i in range(ops_per_worker):
                        op_start = time.perf_counter_ns()
                        worker.call("echo", {"seq": i})
                        op_end = time.perf_counter_ns()
                        worker_latencies.append(op_end - op_start)
                    return worker_latencies

                futures = [executor.submit(worker_task, w) for w in workers]
                for future in concurrent.futures.as_completed(futures):
                    latencies_ns.extend(future.result())

            end = time.perf_counter_ns()
            total_time_ms = (end - start) / 1_000_000

            # Cleanup
            for w in workers:
                w.terminate()

            results.append(
                ConcurrentResult(
                    num_workers=num_workers,
                    ops_per_worker=ops_per_worker,
                    total_ops=num_workers * ops_per_worker,
                    total_time_ms=total_time_ms,
                    ops_per_sec=(num_workers * ops_per_worker) / (total_time_ms / 1000),
                    per_worker_latency_ms=LatencyStats.from_ns_samples(latencies_ns),
                )
            )

        return results

    def benchmark_fault_recovery(self) -> FaultRecoveryResult:
        """Measure time to detect failure and respawn."""
        # Create a worker
        worker = spawn_jsonrpc_worker()
        worker.call("initialize", {}, timeout=5.0)

        # Send crash command with delay so we can measure detection
        try:
            worker.call("crash", {"graceful": True, "delay": 0.01}, timeout=0.5)
        except TimeoutError:
            pass  # Expected, worker is dying

        # Wait for process to actually exit
        detection_start = time.perf_counter_ns()
        while worker.is_alive():
            time.sleep(0.001)
        detection_end = time.perf_counter_ns()

        detection_time_ms = (detection_end - detection_start) / 1_000_000

        # Time respawn
        respawn_start = time.perf_counter_ns()
        new_worker = spawn_jsonrpc_worker()
        new_worker.call("initialize", {}, timeout=5.0)
        respawn_end = time.perf_counter_ns()

        respawn_time_ms = (respawn_end - respawn_start) / 1_000_000

        new_worker.terminate()

        return FaultRecoveryResult(
            detection_time_ms=detection_time_ms,
            respawn_time_ms=respawn_time_ms,
            total_recovery_ms=detection_time_ms + respawn_time_ms,
        )


class PythonOnlyBenchmark:
    """Python-only approach using direct calls and asyncio."""

    name = "python_only"

    def __init__(self, mode: BenchmarkMode):
        self.mode = mode
        self.warmup_runs = (
            QUICK_WARMUP_RUNS if mode == BenchmarkMode.QUICK else DEFAULT_WARMUP_RUNS
        )
        self.runs = (
            QUICK_BENCHMARK_RUNS
            if mode == BenchmarkMode.QUICK
            else DEFAULT_BENCHMARK_RUNS
        )

    def _echo_function(self, msg: dict[str, Any]) -> dict[str, Any]:
        """Direct function call equivalent of echo."""
        return {"echo": msg, "received_ns": time.perf_counter_ns()}

    def benchmark_spawn_latency(self) -> LatencyStats:
        """Measure time to spawn Python subprocess and get ready."""
        latencies_ns: list[int] = []

        # Warmup
        for _ in range(self.warmup_runs):
            # Simulating "spawn" by importing fresh module
            proc = subprocess.Popen(
                [sys.executable, "-c", "import sys; sys.exit(0)"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            proc.wait()

        # Benchmark
        for _ in range(self.runs):
            start = time.perf_counter_ns()
            proc = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import sys; print('ready', flush=True); sys.exit(0)",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            # Wait for "ready" signal
            output = proc.stdout.readline()
            proc.wait()
            end = time.perf_counter_ns()

            if "ready" in output:
                latencies_ns.append(end - start)

        return LatencyStats.from_ns_samples(latencies_ns)

    def benchmark_request_latency(self) -> LatencyStats:
        """Measure direct function call latency."""
        latencies_ns: list[int] = []

        # Warmup
        for _ in range(self.warmup_runs):
            self._echo_function({"msg": "warmup"})

        # Benchmark direct function calls
        for _ in range(self.runs):
            start = time.perf_counter_ns()
            self._echo_function({"msg": "benchmark"})
            end = time.perf_counter_ns()
            latencies_ns.append(end - start)

        return LatencyStats.from_ns_samples(latencies_ns)

    def benchmark_throughput(self) -> ThroughputResult:
        """Measure throughput with direct calls."""
        total_ops = 100 if self.mode == BenchmarkMode.QUICK else 1000
        latencies_ns: list[int] = []

        start = time.perf_counter_ns()
        for i in range(total_ops):
            op_start = time.perf_counter_ns()
            self._echo_function({"seq": i})
            op_end = time.perf_counter_ns()
            latencies_ns.append(op_end - op_start)
        end = time.perf_counter_ns()

        total_time_ms = (end - start) / 1_000_000

        return ThroughputResult(
            total_ops=total_ops,
            total_time_ms=total_time_ms,
            ops_per_sec=total_ops / (total_time_ms / 1000),
            latency_per_op_ms=LatencyStats.from_ns_samples(latencies_ns),
        )

    def benchmark_concurrent(self) -> list[ConcurrentResult]:
        """Measure concurrent performance with threading/async."""
        worker_counts = (
            [1, 2, 4, 8, 16] if self.mode == BenchmarkMode.FULL else [1, 4, 8]
        )
        ops_per_worker = 25 if self.mode == BenchmarkMode.QUICK else 100
        results: list[ConcurrentResult] = []

        for num_workers in worker_counts:
            latencies_ns: list[int] = []
            start = time.perf_counter_ns()

            with ThreadPoolExecutor(max_workers=num_workers) as executor:

                def worker_task(worker_id: int) -> list[int]:
                    worker_latencies: list[int] = []
                    for i in range(ops_per_worker):
                        op_start = time.perf_counter_ns()
                        self._echo_function({"worker": worker_id, "seq": i})
                        op_end = time.perf_counter_ns()
                        worker_latencies.append(op_end - op_start)
                    return worker_latencies

                futures = [executor.submit(worker_task, i) for i in range(num_workers)]
                for future in concurrent.futures.as_completed(futures):
                    latencies_ns.extend(future.result())

            end = time.perf_counter_ns()
            total_time_ms = (end - start) / 1_000_000

            results.append(
                ConcurrentResult(
                    num_workers=num_workers,
                    ops_per_worker=ops_per_worker,
                    total_ops=num_workers * ops_per_worker,
                    total_time_ms=total_time_ms,
                    ops_per_sec=(num_workers * ops_per_worker) / (total_time_ms / 1000),
                    per_worker_latency_ms=LatencyStats.from_ns_samples(latencies_ns),
                )
            )

        return results

    def benchmark_fault_recovery(self) -> FaultRecoveryResult:
        """Measure fault detection and recovery in Python subprocess."""
        # Start a subprocess that we can crash
        proc = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; import time; print('ready', flush=True); time.sleep(60)",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Wait for ready
        proc.stdout.readline()

        proc.terminate()

        detection_start = time.perf_counter_ns()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        detection_end = time.perf_counter_ns()

        detection_time_ms = (detection_end - detection_start) / 1_000_000

        # Time respawn
        respawn_start = time.perf_counter_ns()
        new_proc = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('ready', flush=True); sys.exit(0)",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        new_proc.stdout.readline()
        new_proc.wait()
        respawn_end = time.perf_counter_ns()

        respawn_time_ms = (respawn_end - respawn_start) / 1_000_000

        return FaultRecoveryResult(
            detection_time_ms=detection_time_ms,
            respawn_time_ms=respawn_time_ms,
            total_recovery_ms=detection_time_ms + respawn_time_ms,
        )


# ============================================================================
# Result Formatting and Output
# ============================================================================


def format_latency(stats: LatencyStats) -> str:
    """Format latency stats for display."""
    return (
        f"  mean={stats.mean_ms:.3f}ms, median={stats.median_ms:.3f}ms, "
        f"p95={stats.p95_ms:.3f}ms, p99={stats.p99_ms:.3f}ms, "
        f"stdev={stats.stdev_ms:.3f}ms (n={stats.samples})"
    )


def format_comparison(elixir_stats: LatencyStats, python_stats: LatencyStats) -> str:
    """Format comparison between approaches."""
    ratio = (
        elixir_stats.mean_ms / python_stats.mean_ms if python_stats.mean_ms > 0 else 0
    )
    slower_faster = "slower" if ratio > 1 else "faster"
    return f"  Elixir Control Plane is {ratio:.2f}x {slower_faster} than Python-Only"


def run_benchmarks(
    benchmarks_to_run: list[str], mode: BenchmarkMode, verbose: bool = False
) -> dict[str, BenchmarkResult]:
    """Run all requested benchmarks and return results."""
    from datetime import datetime, timezone

    timestamp = datetime.now(timezone.utc).isoformat()

    # Initialize benchmarkers
    elixir_bench = ElixirControlPlaneBenchmark(mode)
    python_bench = PythonOnlyBenchmark(mode)

    elixir_result = BenchmarkResult(
        approach="elixir_control_plane", timestamp=timestamp, mode=mode.value
    )
    python_result = BenchmarkResult(
        approach="python_only", timestamp=timestamp, mode=mode.value
    )

    # Spawn Latency
    if "spawn" in benchmarks_to_run:
        print("\n" + "=" * 60)
        print("BENCHMARK 1: Spawn Latency")
        print("=" * 60)

        print("\nRunning Elixir Control Plane (JSON-RPC over pipes)...")
        elixir_result.spawn_latency = elixir_bench.benchmark_spawn_latency()
        print(format_latency(elixir_result.spawn_latency))

        print("\nRunning Python-Only (direct subprocess)...")
        python_result.spawn_latency = python_bench.benchmark_spawn_latency()
        print(format_latency(python_result.spawn_latency))

        print("\n" + "-" * 40)
        print(
            format_comparison(elixir_result.spawn_latency, python_result.spawn_latency)
        )

    # Request Latency
    if "latency" in benchmarks_to_run:
        print("\n" + "=" * 60)
        print("BENCHMARK 2: Request/Response Latency")
        print("=" * 60)

        print("\nRunning Elixir Control Plane (JSON-RPC round-trip)...")
        elixir_result.request_latency = elixir_bench.benchmark_request_latency()
        print(format_latency(elixir_result.request_latency))

        print("\nRunning Python-Only (direct function call)...")
        python_result.request_latency = python_bench.benchmark_request_latency()
        print(format_latency(python_result.request_latency))

        print("\n" + "-" * 40)
        print(
            format_comparison(
                elixir_result.request_latency, python_result.request_latency
            )
        )

    # Throughput
    if "throughput" in benchmarks_to_run:
        print("\n" + "=" * 60)
        print("BENCHMARK 3: Throughput Under Load")
        print("=" * 60)

        print("\nRunning Elixir Control Plane...")
        elixir_result.throughput = elixir_bench.benchmark_throughput()
        print(f"  Total ops: {elixir_result.throughput.total_ops}")
        print(f"  Total time: {elixir_result.throughput.total_time_ms:.2f}ms")
        print(f"  Throughput: {elixir_result.throughput.ops_per_sec:.2f} ops/sec")
        print("  Per-op latency:")
        print(
            "   "
            + format_latency(elixir_result.throughput.latency_per_op_ms).replace(
                "  ", " "
            )
        )

        print("\nRunning Python-Only...")
        python_result.throughput = python_bench.benchmark_throughput()
        print(f"  Total ops: {python_result.throughput.total_ops}")
        print(f"  Total time: {python_result.throughput.total_time_ms:.2f}ms")
        print(f"  Throughput: {python_result.throughput.ops_per_sec:.2f} ops/sec")
        print("  Per-op latency:")
        print(
            "   "
            + format_latency(python_result.throughput.latency_per_op_ms).replace(
                "  ", " "
            )
        )

        ratio = (
            elixir_result.throughput.ops_per_sec / python_result.throughput.ops_per_sec
        )
        slower_faster = "slower" if ratio < 1 else "faster"
        print(f"\n{'-' * 40}")
        print(
            f"  Elixir Control Plane is {1 / ratio:.2f}x {slower_faster} than Python-Only"
        )

    # Concurrent Workers
    if "concurrent" in benchmarks_to_run:
        print("\n" + "=" * 60)
        print("BENCHMARK 4: Concurrent Workers")
        print("=" * 60)

        print("\nRunning Elixir Control Plane...")
        elixir_result.concurrent = elixir_bench.benchmark_concurrent()
        for result in elixir_result.concurrent:
            print(f"\n  Workers: {result.num_workers}")
            print(f"    Total ops: {result.total_ops}")
            print(f"    Throughput: {result.ops_per_sec:.2f} ops/sec")
            print("    Per-op latency:")
            print(
                "     "
                + format_latency(result.per_worker_latency_ms).replace("  ", " ")
            )

        print("\nRunning Python-Only...")
        python_result.concurrent = python_bench.benchmark_concurrent()
        for result in python_result.concurrent:
            print(f"\n  Workers: {result.num_workers}")
            print(f"    Total ops: {result.total_ops}")
            print(f"    Throughput: {result.ops_per_sec:.2f} ops/sec")
            print("    Per-op latency:")
            print(
                "     "
                + format_latency(result.per_worker_latency_ms).replace("  ", " ")
            )

    # Fault Recovery
    if "fault" in benchmarks_to_run:
        print("\n" + "=" * 60)
        print("BENCHMARK 5: Fault Recovery")
        print("=" * 60)

        print("\nRunning Elixir Control Plane...")
        elixir_result.fault_recovery = elixir_bench.benchmark_fault_recovery()
        print(
            f"  Detection time: {elixir_result.fault_recovery.detection_time_ms:.3f}ms"
        )
        print(f"  Respawn time: {elixir_result.fault_recovery.respawn_time_ms:.3f}ms")
        print(
            f"  Total recovery: {elixir_result.fault_recovery.total_recovery_ms:.3f}ms"
        )

        print("\nRunning Python-Only...")
        python_result.fault_recovery = python_bench.benchmark_fault_recovery()
        print(
            f"  Detection time: {python_result.fault_recovery.detection_time_ms:.3f}ms"
        )
        print(f"  Respawn time: {python_result.fault_recovery.respawn_time_ms:.3f}ms")
        print(
            f"  Total recovery: {python_result.fault_recovery.total_recovery_ms:.3f}ms"
        )

    return {"elixir_control_plane": elixir_result, "python_only": python_result}


def serialize_results(results: dict[str, BenchmarkResult]) -> dict:
    """Convert results to JSON-serializable dict."""

    def asdict_recursive(obj):
        if isinstance(
            obj,
            (
                LatencyStats,
                ThroughputResult,
                ConcurrentResult,
                FaultRecoveryResult,
                BenchmarkResult,
            ),
        ):
            return {k: asdict_recursive(v) for k, v in asdict(obj).items()}
        elif isinstance(obj, list):
            return [asdict_recursive(item) for item in obj]
        elif isinstance(obj, dict):
            return {k: asdict_recursive(v) for k, v in obj.items()}
        else:
            return obj

    return asdict_recursive(results)


def main():
    """Main entry point for the benchmark suite."""
    parser = argparse.ArgumentParser(
        description="Benchmark Elixir Control Plane vs Python-Only approaches",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    %(prog)s                           # Run all benchmarks
    %(prog)s --quick                   # Quick mode for CI (fewer iterations)
    %(prog)s --output results.json     # Save results to JSON
    %(prog)s --benchmarks spawn,latency # Run only specific benchmarks
""",
    )

    parser.add_argument(
        "--quick",
        "-q",
        action="store_true",
        help="Run in quick mode with fewer iterations (for CI)",
    )

    parser.add_argument("--output", "-o", type=str, help="Output results to JSON file")

    parser.add_argument(
        "--benchmarks",
        "-b",
        type=str,
        default="spawn,latency,throughput,concurrent,fault",
        help="Comma-separated list of benchmarks to run (default: all)",
    )

    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Enable verbose output"
    )

    args = parser.parse_args()

    # Validate worker script exists
    if not WORKER_SCRIPT.exists():
        print(f"Error: Worker script not found at {WORKER_SCRIPT}")
        sys.exit(1)

    # Parse benchmark list
    available_benchmarks = {"spawn", "latency", "throughput", "concurrent", "fault"}
    requested = set(args.benchmarks.split(","))
    invalid = requested - available_benchmarks
    if invalid:
        print(f"Error: Invalid benchmarks: {invalid}")
        print(f"Available: {available_benchmarks}")
        sys.exit(1)

    benchmarks_to_run = list(requested)
    mode = BenchmarkMode.QUICK if args.quick else BenchmarkMode.FULL

    print("=" * 60)
    print("ELIXIR CONTROL PLANE vs PYTHON-ONLY BENCHMARK SUITE")
    print("=" * 60)
    print(f"\nMode: {mode.value.upper()}")
    print(f"Benchmarks: {', '.join(benchmarks_to_run)}")
    print(f"Worker Script: {WORKER_SCRIPT}")

    # Run benchmarks
    results = run_benchmarks(benchmarks_to_run, mode, args.verbose)

    # Output JSON if requested
    if args.output:
        serializable = serialize_results(results)
        with open(args.output, "w") as f:
            json.dump(serializable, f, indent=2)
        print(f"\n\nResults saved to: {args.output}")

    # Print summary
    print("\n" + "=" * 60)
    print("BENCHMARK COMPLETE")
    print("=" * 60)

    return 0


if __name__ == "__main__":
    sys.exit(main())
