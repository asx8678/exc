"""Benchmark Python vs Elixir message processing operations.

This module benchmarks the performance of message operations comparing:
1. Pure Python implementations (baseline)
2. Elixir implementations via JSON-RPC transport (when available)

Metrics:
- Serialization throughput (messages/sec)
- Hash computation time (ops/sec)
- Pruning time for large message sets (time)

Run standalone:
    python benchmarks/bench_message_ops.py

Run as pytest:
    pytest benchmarks/bench_message_ops.py -v
"""

from __future__ import annotations

import hashlib
import json
import statistics
import time
from dataclasses import dataclass, field
from typing import Any, Callable


@dataclass
class BenchmarkResult:
    """Result of a single benchmark run."""

    name: str
    python_time_ms: float
    elixir_time_ms: float | None
    metric: str
    python_value: float
    elixir_value: float | None = None
    iterations: int = 100

    def __str__(self) -> str:
        lines = [f"\n{'=' * 60}", f"Benchmark: {self.name}", "=" * 60]

        if self.python_time_ms > 0:
            lines.append(
                f" Python: {self.python_time_ms:.3f} ms ({self.python_value:.2f} {self.metric})"
            )

        if self.elixir_time_ms is not None and self.elixir_time_ms > 0:
            lines.append(
                f" Elixir: {self.elixir_time_ms:.3f} ms ({self.elixir_value:.2f} {self.metric})"
            )
            if self.python_time_ms > 0:
                ratio = (
                    self.python_time_ms / self.elixir_time_ms
                    if self.elixir_time_ms > 0
                    else 0
                )
                winner = "Python" if ratio > 1 else "Elixir"
                lines.append(
                    f" Winner: {winner} ({ratio:.2f}x {'faster' if ratio > 1 else 'slower'})"
                )
        else:
            lines.append(" Elixir: not available")

        lines.append(f" Iterations: {self.iterations}")
        return "\n".join(lines)


@dataclass
class BenchmarkSuite:
    """Collection of benchmark results."""

    results: list[BenchmarkResult] = field(default_factory=list)
    timestamp: str = field(default_factory=lambda: time.strftime("%Y-%m-%d %H:%M:%S"))

    def add(self, result: BenchmarkResult) -> None:
        self.results.append(result)

    def summary(self) -> str:
        lines = [
            "\n" + "=" * 60,
            "BENCHMARK SUMMARY",
            "=" * 60,
            f"Timestamp: {self.timestamp}",
            f"Total benchmarks: {len(self.results)}",
            "",
        ]
        elixir_wins = 0
        python_wins = 0
        elixir_only = 0
        for r in self.results:
            if r.elixir_time_ms is None or r.elixir_time_ms == 0:
                elixir_only += 1
            elif r.python_time_ms > r.elixir_time_ms:
                elixir_wins += 1
            else:
                python_wins += 1
        comparable = elixir_wins + python_wins
        if comparable > 0:
            lines.append(f"Elixir faster: {elixir_wins}/{comparable}")
            lines.append(f"Python faster: {python_wins}/{comparable}")
        if elixir_only > 0:
            lines.append(f"Elixir-only operations: {elixir_only}")
        lines.append("")
        lines.append("Note: Elixir times include JSON-RPC overhead.")
        lines.append("=" * 60)
        return "\n".join(lines)


def generate_test_messages(count: int, parts_per_msg: int = 2) -> list[dict[str, Any]]:
    messages = []
    for i in range(count):
        parts = []
        for j in range(parts_per_msg):
            if j % 3 == 0:
                parts.append(
                    {
                        "part_kind": "text",
                        "content": f"Message {i} part {j} " * 10,
                        "tool_call_id": None,
                        "tool_name": None,
                    }
                )
            elif j % 3 == 1:
                parts.append(
                    {
                        "part_kind": "tool-call",
                        "content": None,
                        "tool_call_id": f"call_{i}_{j}",
                        "tool_name": f"tool_{j}",
                    }
                )
            else:
                parts.append(
                    {
                        "part_kind": "tool-return",
                        "content": f"Result for call_{i}_{j - 1}" * 10,
                        "tool_call_id": f"call_{i}_{j - 1}",
                        "tool_name": None,
                    }
                )
        messages.append(
            {
                "kind": "request" if i % 2 == 0 else "response",
                "role": "user" if i % 2 == 0 else "assistant",
                "parts": parts,
            }
        )
    return messages


def time_function(
    func: Callable[[], Any], iterations: int = 100
) -> tuple[float, list[Any]]:
    times = []
    results = []
    for _ in range(min(5, iterations // 10)):
        func()
    for _ in range(iterations):
        start = time.perf_counter()
        result = func()
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
        results.append(result)
    median_time = statistics.median(times)
    return median_time, results


def time_function_throughput(
    func: Callable[[], Any], iterations: int = 100, item_count: int = 1
) -> tuple[float, float]:
    median_time, _ = time_function(func, iterations)
    items_per_sec = (
        (item_count * iterations / median_time) * 1000 if median_time > 0 else 0
    )
    return median_time, items_per_sec


def python_serialize(messages: list[dict[str, Any]]) -> bytes:
    return json.dumps(messages).encode("utf-8")


def python_deserialize(data: bytes) -> list[dict[str, Any]]:
    return json.loads(data.decode("utf-8"))


def python_hash_message(msg: dict[str, Any]) -> str:
    parts_str = ""
    for part in msg.get("parts", []):
        parts_str += f"{part.get('part_kind', '')}|"
        parts_str += f"tool_call_id={part.get('tool_call_id', '')}|"
        parts_str += f"tool_name={part.get('tool_name', '')}|"
        parts_str += f"content={part.get('content', '')}||"
    header = f"role={msg.get('role', '')}||"
    canonical = header + parts_str
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def python_hash_batch(messages: list[dict[str, Any]]) -> list[str]:
    return [python_hash_message(m) for m in messages]


def python_prune_and_filter(messages: list[dict[str, Any]]) -> dict[str, Any]:
    call_ids: set[str] = set()
    return_ids: set[str] = set()
    for msg in messages:
        for part in msg.get("parts", []):
            tcid = part.get("tool_call_id")
            if tcid and isinstance(tcid, str):
                if part.get("part_kind") == "tool-call":
                    call_ids.add(tcid)
                elif part.get("part_kind") == "tool-return":
                    return_ids.add(tcid)
    mismatched = call_ids.symmetric_difference(return_ids)
    surviving: list[int] = []
    dropped = 0
    for i, msg in enumerate(messages):
        has_mismatch = False
        for part in msg.get("parts", []):
            if part.get("tool_call_id") in mismatched:
                has_mismatch = True
                break
        if has_mismatch:
            dropped += 1
        else:
            surviving.append(i)
    return {
        "surviving_indices": surviving,
        "dropped_count": dropped,
        "had_pending_tool_calls": len(call_ids - return_ids) > 0,
        "pending_tool_call_count": len(call_ids - return_ids),
    }


def get_elixir_transport() -> Any | None:
    try:
        from code_puppy import message_transport

        return message_transport
    except ImportError:
        return None


def elixir_available() -> bool:
    return get_elixir_transport() is not None


def bench_serialization(
    iterations: int = 100, message_counts: list[int] | None = None
) -> list[BenchmarkResult]:
    if message_counts is None:
        message_counts = [10, 50, 100]
    results = []
    elixir_transport = get_elixir_transport()
    for count in message_counts:
        messages = generate_test_messages(count, parts_per_msg=3)
        py_time, py_throughput = time_function_throughput(
            lambda: python_serialize(messages), iterations=iterations, item_count=count
        )
        ex_time: float | None = None
        ex_throughput: float | None = None
        if elixir_transport:
            ex_time, ex_throughput = time_function_throughput(
                lambda: elixir_transport.serialize_session(messages),
                iterations=iterations,
                item_count=count,
            )
        results.append(
            BenchmarkResult(
                name=f"serialize ({count} msgs)",
                python_time_ms=py_time,
                elixir_time_ms=ex_time,
                metric="messages/sec",
                python_value=py_throughput,
                elixir_value=ex_throughput,
                iterations=iterations,
            )
        )
        py_data = python_serialize(messages)
        py_time, py_throughput = time_function_throughput(
            lambda: python_deserialize(py_data), iterations=iterations, item_count=count
        )
        ex_time = None
        ex_throughput = None
        if elixir_transport:
            ex_data = elixir_transport.serialize_session(messages)
            ex_time, ex_throughput = time_function_throughput(
                lambda: elixir_transport.deserialize_session(ex_data),
                iterations=iterations,
                item_count=count,
            )
        results.append(
            BenchmarkResult(
                name=f"deserialize ({count} msgs)",
                python_time_ms=py_time,
                elixir_time_ms=ex_time,
                metric="messages/sec",
                python_value=py_throughput,
                elixir_value=ex_throughput,
                iterations=iterations,
            )
        )
    return results


def bench_hash_computation(
    iterations: int = 100, message_counts: list[int] | None = None
) -> list[BenchmarkResult]:
    if message_counts is None:
        message_counts = [1, 10, 50]
    results = []
    elixir_transport = get_elixir_transport()
    medium_messages = generate_test_messages(50, parts_per_msg=3)
    single_msg = medium_messages[0]
    py_time, py_ops = time_function_throughput(
        lambda: python_hash_message(single_msg), iterations=iterations, item_count=1
    )
    ex_time: float | None = None
    ex_ops: float | None = None
    if elixir_transport:
        ex_time, ex_ops = time_function_throughput(
            lambda: elixir_transport.hash_message(single_msg),
            iterations=iterations,
            item_count=1,
        )
    results.append(
        BenchmarkResult(
            name="hash_message (single)",
            python_time_ms=py_time,
            elixir_time_ms=ex_time,
            metric="ops/sec",
            python_value=py_ops,
            elixir_value=ex_ops,
            iterations=iterations,
        )
    )
    for count in message_counts:
        if count == 1:
            continue
        messages = medium_messages[:count]
        py_time, py_ops = time_function_throughput(
            lambda: python_hash_batch(messages), iterations=iterations, item_count=count
        )
        ex_time = None
        ex_ops = None
        if elixir_transport:
            ex_time, ex_ops = time_function_throughput(
                lambda: elixir_transport.hash_batch(messages),
                iterations=iterations,
                item_count=count,
            )
        results.append(
            BenchmarkResult(
                name=f"hash_batch ({count} msgs)",
                python_time_ms=py_time,
                elixir_time_ms=ex_time,
                metric="ops/sec",
                python_value=py_ops,
                elixir_value=ex_ops,
                iterations=iterations,
            )
        )
    return results


def bench_pruning(
    iterations: int = 50, message_counts: list[int] | None = None
) -> list[BenchmarkResult]:
    if message_counts is None:
        message_counts = [10, 100, 200]
    results = []
    elixir_transport = get_elixir_transport()
    for count in message_counts:
        messages = generate_test_messages(count, parts_per_msg=4)
        py_time, _ = time_function(
            lambda: python_prune_and_filter(messages), iterations=iterations
        )
        ex_time: float | None = None
        if elixir_transport:
            ex_time, _ = time_function(
                lambda: elixir_transport.prune_and_filter(messages),
                iterations=iterations,
            )
        results.append(
            BenchmarkResult(
                name=f"prune_and_filter ({count} msgs)",
                python_time_ms=py_time,
                elixir_time_ms=ex_time,
                metric="ms",
                python_value=py_time,
                elixir_value=ex_time,
                iterations=iterations,
            )
        )
    return results


def run_all_benchmarks(
    iterations: int = 100, include_elixir: bool = True
) -> BenchmarkSuite:
    suite = BenchmarkSuite()
    has_elixir = elixir_available() if include_elixir else False
    print("🐶 Message Operations Benchmark Suite")
    print("=" * 60)
    print(f"Iterations: {iterations}")
    print(f"Elixir available: {has_elixir}")
    print("=" * 60)
    print()
    if has_elixir:
        print("Warming up Elixir transport...")
        elixir_transport = get_elixir_transport()
        if elixir_transport:
            test_msgs = generate_test_messages(5, parts_per_msg=2)
            try:
                _ = elixir_transport.hash_message(test_msgs[0])
                print("✓ Elixir transport ready")
            except Exception as e:
                print(f"⚠ Elixir warmup failed: {e}")
        print()
    print("### Serialization Operations")
    for result in bench_serialization(iterations=iterations):
        suite.add(result)
        print(result)
    print()
    print("### Hash Computation Operations")
    for result in bench_hash_computation(iterations=iterations):
        suite.add(result)
        print(result)
    print()
    print("### Pruning Operations")
    for result in bench_pruning(iterations=max(iterations // 2, 50)):
        suite.add(result)
        print(result)
    print()
    return suite


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Benchmark Python vs Elixir message processing",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python benchmarks/bench_message_ops.py
    python benchmarks/bench_message_ops.py --quick
    python benchmarks/bench_message_ops.py --iters 200
""",
    )
    parser.add_argument("--quick", "-q", action="store_true", help="Quick mode")
    parser.add_argument("--iters", "-i", type=int, default=None, help="Iterations")
    parser.add_argument("--python-only", action="store_true", help="Python only")
    args = parser.parse_args()
    iterations = args.iters or (50 if args.quick else 100)
    include_elixir = not args.python_only
    suite = run_all_benchmarks(iterations=iterations, include_elixir=include_elixir)
    print(suite.summary())
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
