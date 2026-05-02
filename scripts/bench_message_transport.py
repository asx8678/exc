#!/usr/bin/env python3
"""Benchmark Python vs Elixir message processing.

This script benchmarks the performance of message operations using:
1. Pure Python implementations (baseline)
2. Elixir implementations via JSON-RPC transport

Run with:
    python scripts/bench_message_transport.py

Output is written to stdout as a markdown table for easy comparison.
"""

import hashlib
import json
import statistics
import time
from dataclasses import dataclass
from typing import Any, Callable


@dataclass
class BenchmarkResult:
    """Result of a benchmark run."""

    name: str
    python_ms: float
    elixir_ms: float
    speedup: float
    iterations: int

    def __str__(self) -> str:
        if self.python_ms == 0:
            return f"| {self.name} | - | {self.elixir_ms:.3f}ms | Elixir only |"
        faster = "Elixir" if self.speedup > 1 else "Python"
        ratio = self.speedup if self.speedup > 1 else 1 / self.speedup
        return f"| {self.name} | {self.python_ms:.3f}ms | {self.elixir_ms:.3f}ms | {ratio:.2f}x {faster} |"


def generate_test_messages(count: int, parts_per_msg: int = 2) -> list[dict[str, Any]]:
    """Generate test messages for benchmarking."""
    messages = []
    for i in range(count):
        parts = []
        for j in range(parts_per_msg):
            if j % 3 == 0:
                parts.append(
                    {
                        "part_kind": "text",
                        "content": f"Message {i} part {j} with some content that makes it realistic "
                        * 5,
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


def time_function(func: Callable, iterations: int = 100) -> float:
    """Time a function over multiple iterations, return median ms."""
    times = []
    for _ in range(iterations):
        start = time.perf_counter()
        func()
        elapsed = (time.perf_counter() - start) * 1000  # ms
        times.append(elapsed)
    return statistics.median(times)


# =============================================================================
# Python Baseline Implementations
# =============================================================================


def python_hash_message(msg: dict) -> str:
    """Python baseline: SHA256 hash of message."""
    parts_str = ""
    for part in msg.get("parts", []):
        parts_str += f"{part.get('part_kind', '')}|"
        parts_str += f"tool_call_id={part.get('tool_call_id', '')}|"
        parts_str += f"tool_name={part.get('tool_name', '')}|"
        parts_str += f"content={part.get('content', '')}||"

    header = f"role={msg.get('role', '')}||"
    canonical = header + parts_str
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def python_prune_and_filter(messages: list[dict]) -> dict:
    """Python baseline: prune orphaned tool calls."""
    call_ids = set()
    return_ids = set()

    for msg in messages:
        for part in msg.get("parts", []):
            tcid = part.get("tool_call_id")
            if tcid:
                if part.get("part_kind") == "tool-call":
                    call_ids.add(tcid)
                else:
                    return_ids.add(tcid)

    mismatched = call_ids.symmetric_difference(return_ids)

    surviving = []
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


def python_serialize(messages: list[dict]) -> bytes:
    """Python baseline: JSON serialization."""
    return json.dumps(messages).encode("utf-8")


def python_deserialize(data: bytes) -> list[dict]:
    """Python baseline: JSON deserialization."""
    return json.loads(data.decode("utf-8"))


# =============================================================================
# Benchmark Runner
# =============================================================================


def run_benchmarks() -> list[BenchmarkResult]:
    """Run all benchmarks and return results."""
    results = []

    # Import Elixir transport
    try:
        from code_puppy import message_transport
    except ImportError:
        print("⚠️ Elixir transport not available, skipping Elixir benchmarks")
        return results

    # Generate test data
    small_messages = generate_test_messages(10, parts_per_msg=2)
    medium_messages = generate_test_messages(50, parts_per_msg=3)
    large_messages = generate_test_messages(200, parts_per_msg=4)

    print("🐶 Message Transport Benchmark")
    print("=" * 60)
    print()

    # Warm up Elixir transport
    print("Warming up Elixir transport...")
    _ = message_transport.hash_message(small_messages[0])
    print()

    iterations = 50

    # ----- Hash benchmarks -----
    print("### Hash Operations")
    print()

    # Single message hash
    msg = medium_messages[0]
    py_time = time_function(lambda: python_hash_message(msg), iterations)
    ex_time = time_function(lambda: message_transport.hash_message(msg), iterations)
    results.append(
        BenchmarkResult(
            "hash_message (1 msg)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # Batch hash (50 messages)
    py_time = time_function(
        lambda: [python_hash_message(m) for m in medium_messages], iterations
    )
    ex_time = time_function(
        lambda: message_transport.hash_batch(medium_messages), iterations
    )
    results.append(
        BenchmarkResult(
            "hash_batch (50 msgs)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # ----- Pruning benchmarks -----
    print("### Pruning Operations")
    print()

    # Small set
    py_time = time_function(lambda: python_prune_and_filter(small_messages), iterations)
    ex_time = time_function(
        lambda: message_transport.prune_and_filter(small_messages), iterations
    )
    results.append(
        BenchmarkResult(
            "prune (10 msgs)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # Large set
    py_time = time_function(lambda: python_prune_and_filter(large_messages), iterations)
    ex_time = time_function(
        lambda: message_transport.prune_and_filter(large_messages), iterations
    )
    results.append(
        BenchmarkResult(
            "prune (200 msgs)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # ----- Serialization benchmarks -----
    print("### Serialization Operations")
    print()

    # Serialize medium
    py_time = time_function(lambda: python_serialize(medium_messages), iterations)
    ex_time = time_function(
        lambda: message_transport.serialize_session(medium_messages), iterations
    )
    results.append(
        BenchmarkResult(
            "serialize (50 msgs)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # Round-trip medium
    py_data = python_serialize(medium_messages)
    ex_data = message_transport.serialize_session(medium_messages)

    py_time = time_function(lambda: python_deserialize(py_data), iterations)
    ex_time = time_function(
        lambda: message_transport.deserialize_session(ex_data), iterations
    )
    results.append(
        BenchmarkResult(
            "deserialize (50 msgs)", py_time, ex_time, py_time / ex_time, iterations
        )
    )

    # ----- Truncation benchmarks -----
    print("### Truncation Operations")
    print()

    tokens = [100 + (i * 10) for i in range(200)]

    # Pure Python doesn't have truncation_indices, so compare against 0
    ex_time = time_function(
        lambda: message_transport.truncation_indices(tokens, 5000), iterations
    )
    results.append(
        BenchmarkResult("truncation_indices (200)", 0.0, ex_time, 0.0, iterations)
    )

    return results


def print_results(results: list[BenchmarkResult]) -> None:
    """Print results as markdown table."""
    print()
    print("## Results")
    print()
    print("| Operation | Python | Elixir | Winner |")
    print("|-----------|--------|--------|--------|")
    for r in results:
        print(str(r))
    print()

    # Summary stats
    elixir_wins = sum(1 for r in results if r.speedup > 1 and r.python_ms > 0)
    python_wins = sum(1 for r in results if r.speedup < 1 and r.python_ms > 0)
    total_comparable = sum(1 for r in results if r.python_ms > 0)

    print("## Summary")
    print()
    print(f"- **Elixir faster**: {elixir_wins}/{total_comparable} operations")
    print(f"- **Python faster**: {python_wins}/{total_comparable} operations")
    print()
    print("Note: Elixir times include JSON-RPC overhead (serialization + IPC).")
    print("For large batches, Elixir's native processing may outweigh IPC cost.")


def main():
    """Run benchmarks and print results."""
    try:
        results = run_benchmarks()
        if results:
            print_results(results)
    except Exception as e:
        print(f"❌ Benchmark failed: {e}")
        raise


if __name__ == "__main__":
    main()
