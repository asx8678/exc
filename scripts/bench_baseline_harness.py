#!/usr/bin/env python3
"""
Baseline Performance Benchmark Harness for Python-to-Elixir Migration

This script establishes reproducible baseline performance metrics for two
categories from ROADMAP.md:
1. Tool execution overhead (file ops, grep, read_file) - offline filesystem primitives
2. LLM request latency - minimal credential-gated probe (if PUP_*_API_KEY set)

Design principles:
- Deterministic and offline by default (no external services required)
- Safe timeouts on all operations (actually enforced)
- JSON output for CI integration
- Truthful about failures vs successes
- Exceptions captured, not swallowed as "successful" latencies

Usage:
    python scripts/bench_baseline_harness.py
    python scripts/bench_baseline_harness.py --quick        # CI mode
    python scripts/bench_baseline_harness.py --output baseline.json
    python scripts/bench_baseline_harness.py --category tools
    python scripts/bench_baseline_harness.py --help
    python scripts/bench_baseline_harness.py --self-test    # Run unit tests

Environment:
    PUP_BENCH_QUICK=1          # Enable quick mode (CI)
    PUP_BENCH_OUTPUT=path.json # Output file path
    PUP_BENCH_CATEGORY=tools   # Category filter
    PUP_ANTHROPIC_API_KEY=...  # For LLM probe (optional)
    PUP_OPENAI_API_KEY=...     # For LLM probe (optional)

Exit codes:
    0 - Success
    1 - Benchmark error
    2 - Invalid arguments
    3 - Self-test failure
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add the package to path
sys.path.insert(0, str(Path(__file__).parent))

from bench_baseline.llm import LLMLatencyBenchmarks
from bench_baseline.models import BenchmarkSuite
from bench_baseline.self_test import run_tests
from bench_baseline.tools import ToolOverheadBenchmarks
from bench_baseline.utils import parse_env_bool, validate_env_choice

# format_stats imported in tools.py for display output


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Baseline Performance Benchmark Harness for Python-to-Elixir Migration",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python scripts/bench_baseline_harness.py                    # Run all
    python scripts/bench_baseline_harness.py --quick              # CI mode
    python scripts/bench_baseline_harness.py --category tools   # Tools only
    python scripts/bench_baseline_harness.py --output data.json # Save results
    python scripts/bench_baseline_harness.py --self-test      # Run self-tests

Environment Variables:
    PUP_BENCH_QUICK=1          # Enable quick mode
    PUP_BENCH_OUTPUT=path.json  # Output file path
    PUP_BENCH_CATEGORY=tools   # Category filter
    PUP_ANTHROPIC_API_KEY=...  # LLM probe credentials
    PUP_OPENAI_API_KEY=...     # LLM probe credentials
""",
    )

    parser.add_argument(
        "--quick",
        "-q",
        action="store_true",
        help="Quick mode with fewer iterations (CI friendly)",
    )
    parser.add_argument(
        "--category",
        "-c",
        choices=["tools", "llm", "all"],
        default="all",
        help="Benchmark category to run",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=str,
        help="Output JSON file path",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run offline self-tests (unittest-based, no pytest required)",
    )

    return parser.parse_args()


def run_comparison_summary(suite: BenchmarkSuite) -> None:
    """Print Python vs Elixir comparison summary."""
    print("\n" + "-" * 40)
    print("Python vs Elixir Comparison:")

    tool_ops = set(r.operation for r in suite.results if r.category == "tool_execution")
    for op in sorted(tool_ops):
        py_results = [
            r for r in suite.results if r.operation == op and "python" in r.approach
        ]
        ex_results = [
            r for r in suite.results if r.operation == op and "elixir" in r.approach
        ]

        if py_results and ex_results:
            py_latency = py_results[0].latency_stats.mean_ms
            ex_latency = ex_results[0].latency_stats.mean_ms
            ratio = ex_latency / py_latency if py_latency > 0 else 0
            faster = "Elixir" if ratio < 1 else "Python"
            print(f"  {op}: {ratio:.2f}x (Elixir vs Python) - {faster} faster")


def main() -> int:
    """Main entry point."""
    args = parse_args()

    # Self-test mode
    if args.self_test:
        print("=" * 60)
        print("Running Self-Tests")
        print("=" * 60)
        return run_tests()

    # Environment overrides (with strict parsing / validation)
    env_quick = parse_env_bool("PUP_BENCH_QUICK", os.environ.get("PUP_BENCH_QUICK"))
    mode = "quick" if (args.quick or env_quick) else "full"
    env_category = validate_env_choice(
        "PUP_BENCH_CATEGORY",
        os.environ.get("PUP_BENCH_CATEGORY"),
        ("all", "tools", "llm"),
    )
    category = env_category if env_category is not None else args.category
    output_path = os.environ.get("PUP_BENCH_OUTPUT", args.output)

    print("=" * 60)
    print("Baseline Performance Benchmark Harness")
    print("Python-to-Elixir Migration - code_puppy-xmx")
    print("=" * 60)
    print(f"Mode: {mode}")
    print(f"Category: {category}")
    print(f"Output: {output_path or 'stdout'}")
    print("=" * 60)

    suite = BenchmarkSuite(
        timestamp=datetime.now(timezone.utc).isoformat(),
        version="1.1.0",
        mode=mode,
    )

    # Run tool execution benchmarks
    if category in ("tools", "all"):
        try:
            tool_bench = ToolOverheadBenchmarks(mode)
            results, failures = tool_bench.run_all()
            for result in results:
                suite.add(result)
            for failure in failures:
                suite.failed_benchmarks.append(failure)
        except Exception as e:
            print(f"\n❌ Tool benchmarks failed: {e}")
            suite.failed_benchmarks.append({"operation": "tool_bench", "error": str(e)})
            return 1

    # Run LLM benchmarks
    if category in ("llm", "all"):
        llm_bench = LLMLatencyBenchmarks(mode)
        results, not_impl = llm_bench.run_all()
        for result in results:
            suite.add(result)
        for ni in not_impl:
            suite.not_implemented.append(ni)

        if not results:
            if not not_impl:
                suite.not_implemented.append("llm_latency")

    # Print summary
    print("\n" + "=" * 60)
    print("Benchmark Summary")
    print("=" * 60)
    print(f"Total benchmarks run: {len(suite.results)}")

    tools_count = sum(1 for r in suite.results if r.category == "tool_execution")
    llm_count = sum(1 for r in suite.results if r.category == "llm_latency")
    llm_streaming_count = sum(1 for r in suite.results if r.category == "llm_streaming")

    print(f"  - Tool execution: {tools_count}")
    print(f"  - LLM latency: {llm_count}")
    print(f"  - LLM streaming: {llm_streaming_count}")

    if suite.failed_benchmarks:
        print(f"\nFailed benchmarks: {len(suite.failed_benchmarks)}")
        for fb in suite.failed_benchmarks[:5]:  # Show first 5
            print(f"  - {fb.get('operation', 'unknown')}: {fb.get('error', 'unknown')}")

    if suite.pending_benchmarks:
        print("\nPending benchmarks:")
        for pending in suite.pending_benchmarks:
            print(f"  - {pending}")

    if suite.not_implemented:
        print("\nNot implemented:")
        for ni in suite.not_implemented:
            print(f"  - {ni}")

    run_comparison_summary(suite)

    # Write output
    if output_path:
        output_file = Path(output_path)
        output_file.parent.mkdir(parents=True, exist_ok=True)
        with open(output_file, "w") as f:
            json.dump(suite.to_dict(), f, indent=2)
        print(f"\nResults written to: {output_path}")

    print("\n" + "=" * 60)
    print("Benchmark complete!")
    print("=" * 60)

    return 0


if __name__ == "__main__":
    sys.exit(main())
