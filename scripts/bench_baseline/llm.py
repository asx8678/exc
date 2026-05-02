"""LLM latency benchmarks - minimal credential-gated probe."""

from __future__ import annotations

import os
import time
from typing import Any

from .models import BenchmarkResult, LatencyStats
from .streaming_probes import StreamingProbes


class LLMLatencyBenchmarks:
    """Minimal credential-gated LLM latency probe.

    Uses PUP_ANTHROPIC_API_KEY or PUP_OPENAI_API_KEY (PUP_ prefix per convention).
    Safe timeout enforced. Returns 'not_implemented' if no credentials.
    """

    def __init__(self, mode: str):
        self.mode = mode
        self.warmup = 0  # No warmup for paid API calls
        self.iterations = 1 if mode == "quick" else 3
        self.timeout = 60.0  # LLM calls need more time

    def _get_credentials(self) -> dict[str, str | None]:
        """Get credentials with PUP_ prefix per convention."""
        return {
            "anthropic": os.environ.get("PUP_ANTHROPIC_API_KEY")
            or os.environ.get("ANTHROPIC_API_KEY"),
            "openai": os.environ.get("PUP_OPENAI_API_KEY")
            or os.environ.get("OPENAI_API_KEY"),
        }

    def _probe_anthropic(self) -> BenchmarkResult | None:
        """Minimal Anthropic latency probe."""
        creds = self._get_credentials()
        api_key = creds.get("anthropic")
        if not api_key:
            return None

        try:
            import anthropic
        except ImportError:
            return None

        client = anthropic.Anthropic(api_key=api_key, timeout=self.timeout)
        prompt = "Write a one-line Python function that adds two numbers."

        def make_request():
            start = time.perf_counter()
            response = client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=50,
                messages=[{"role": "user", "content": prompt}],
            )
            # Measure TTFT (Time to First Token) approximation
            _ = response.content[0].text if response.content else ""
            return (time.perf_counter() - start) * 1000

        # Use manual timing for this async-style call
        times_ms: list[float] = []
        failures: list[dict[str, Any]] = []

        for i in range(self.iterations):
            try:
                latency = make_request()
                times_ms.append(latency)
            except Exception as e:
                failures.append(
                    {"iteration": i, "error": str(e), "type": type(e).__name__}
                )

        if not times_ms:
            return None

        stats = LatencyStats.from_samples(times_ms)
        return BenchmarkResult(
            category="llm_latency",
            operation="anthropic_ttfb",
            approach="live_api",
            latency_stats=stats,
            throughput_ops_per_sec=0,  # Not meaningful for single-shot LLM
            metadata={
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 50,
                "prompt_chars": len(prompt),
                "failures": len(failures),
            },
            notes="Time to first block (approximates TTFT). Paid API call."
            + (f"; {len(failures)} failures" if failures else ""),
        )

    def _probe_openai(self) -> BenchmarkResult | None:
        """Minimal OpenAI latency probe."""
        creds = self._get_credentials()
        api_key = creds.get("openai")
        if not api_key:
            return None

        try:
            import openai
        except ImportError:
            return None

        client = openai.OpenAI(api_key=api_key, timeout=self.timeout)
        prompt = "Write a one-line Python function that adds two numbers."

        def make_request():
            start = time.perf_counter()
            response = client.chat.completions.create(
                model="gpt-4o-mini",
                max_tokens=50,
                messages=[{"role": "user", "content": prompt}],
            )
            # Force consumption of response
            _ = response.choices[0].message.content if response.choices else ""
            return (time.perf_counter() - start) * 1000

        times_ms: list[float] = []
        failures: list[dict[str, Any]] = []

        for i in range(self.iterations):
            try:
                latency = make_request()
                times_ms.append(latency)
            except Exception as e:
                failures.append(
                    {"iteration": i, "error": str(e), "type": type(e).__name__}
                )

        if not times_ms:
            return None

        stats = LatencyStats.from_samples(times_ms)
        return BenchmarkResult(
            category="llm_latency",
            operation="openai_ttfb",
            approach="live_api",
            latency_stats=stats,
            throughput_ops_per_sec=0,
            metadata={
                "model": "gpt-4o-mini",
                "max_tokens": 50,
                "prompt_chars": len(prompt),
                "failures": len(failures),
            },
            notes="Time to first block (approximates TTFT). Paid API call."
            + (f"; {len(failures)} failures" if failures else ""),
        )

    def run_all(self) -> tuple[list[BenchmarkResult], list[str]]:
        """Run all LLM benchmarks (non-streaming + streaming).

        Returns:
            Tuple of (results, not_implemented_list).
        """
        results: list[BenchmarkResult] = []
        not_implemented: list[str] = []

        creds = self._get_credentials()
        has_creds = bool(creds.get("anthropic") or creds.get("openai"))

        print("\n### LLM Request Latency Benchmarks")
        print("-" * 60)

        if not has_creds:
            print("\n⚠ LLM benchmarks NOT IMPLEMENTED - No credentials found")
            print("   Required: PUP_ANTHROPIC_API_KEY or PUP_OPENAI_API_KEY")
            print("   (ANTHROPIC_API_KEY and OPENAI_API_KEY also accepted)")
            print("   To run LLM benchmarks:")
            print('     export PUP_ANTHROPIC_API_KEY="sk-ant-..."')
            print("     python scripts/bench_baseline_harness.py --category llm")
            not_implemented.append("llm_latency_no_credentials")
            # Also run streaming probes (will report no credentials)
            streaming = StreamingProbes(self.mode, timeout=self.timeout)
            _, stream_ni = streaming.run_all()
            not_implemented.extend(stream_ni)
            return results, not_implemented

        # Try Anthropic
        if creds.get("anthropic"):
            print("\nProbing Anthropic (claude-sonnet-4)...")
            result = self._probe_anthropic()
            if result:
                results.append(result)
                print(f"  ✓ TTBF: mean={result.latency_stats.mean_ms:.1f}ms")
            else:
                print("  ✗ Failed (check API key or anthropic SDK)")
                not_implemented.append("anthropic_probe_failed")

        # Try OpenAI
        if creds.get("openai"):
            print("\nProbing OpenAI (gpt-4o-mini)...")
            result = self._probe_openai()
            if result:
                results.append(result)
                print(f"  ✓ TTBF: mean={result.latency_stats.mean_ms:.1f}ms")
            else:
                print("  ✗ Failed (check API key or openai SDK)")
                not_implemented.append("openai_probe_failed")

        if not results:
            not_implemented.append("llm_latency_all_probes_failed")

        # Run streaming TTFT/TBT probes
        streaming = StreamingProbes(self.mode, timeout=self.timeout)
        stream_results, stream_ni = streaming.run_all()
        results.extend(stream_results)
        not_implemented.extend(stream_ni)

        return results, not_implemented
