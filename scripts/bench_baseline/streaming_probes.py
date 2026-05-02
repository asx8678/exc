"""Credential-gated streaming LLM probes for TTFT/TBT measurement.

Live streaming probes that measure true time-to-first-token (TTFT) and
inter-token gaps (TBT) from Anthropic and OpenAI streaming APIs.

Uses:
- ``compute_streaming_metrics(...)`` from streaming.py for metric computation
- ``streaming_metrics_to_benchmark_metadata(...)`` for BenchmarkResult metadata
- ``streaming_fixtures.get_fixture(...)`` for standardized prompt lookup

Safety:
- No credentials → non-fatal, recorded as not_implemented
- SDK missing → non-fatal, recorded truthfully (None / not_implemented)
- Provider errors → non-fatal, recorded truthfully, never as successful numbers
- Uses monotonic ``time.perf_counter()`` for all timing
"""

from __future__ import annotations

import os
import time
from typing import Any

from .models import BenchmarkResult, LatencyStats
from .streaming import (
    compute_inter_token_gaps,
    compute_streaming_metrics,
    streaming_metrics_to_benchmark_metadata,
)
from .streaming_fixtures import get_fixture

# ---------------------------------------------------------------------------
# Extraction helpers (testable offline with fake chunk objects)
# ---------------------------------------------------------------------------


def extract_anthropic_token_text(event: Any) -> str | None:
    """Extract token text from an Anthropic streaming event.

    Returns the text delta for ``content_block_delta`` events, or None
    for all other event types (message_start, content_block_start, etc.).

    Designed for offline unit testing with lightweight fake objects that
    have ``type`` and ``delta.text`` attributes.
    """
    if hasattr(event, "type") and event.type == "content_block_delta":
        delta = getattr(event, "delta", None)
        if delta is not None and hasattr(delta, "text"):
            return delta.text
    return None


def extract_openai_token_text(chunk: Any) -> str | None:
    """Extract token text from an OpenAI streaming chunk.

    Returns the content delta text, or None when the chunk carries no
    token text (e.g. role-only chunks, usage-only chunks).

    Designed for offline unit testing with lightweight fake objects that
    have ``choices[0].delta.content`` attribute chains.
    """
    choices = getattr(chunk, "choices", None)
    if choices:
        first = choices[0] if len(choices) > 0 else None
        if first is not None:
            delta = getattr(first, "delta", None)
            if delta is not None:
                content = getattr(delta, "content", None)
                if content is not None:
                    return content
    return None


def is_token_arrival(text: str | None) -> bool:
    """Return True if *text* represents an actual token arrival.

    Empty-string deltas (e.g. initial role-only chunks from OpenAI)
    are **not** token arrivals — they would make TTFT too low and pollute
    inter-token gap (TBT) measurements.  Whitespace-only deltas (``" "``,
    ``"\n"``) **are** token arrivals; they carry meaningful content and
    must not be stripped.
    """
    return text is not None and text != ""


# ---------------------------------------------------------------------------
# Credential-gated streaming probes
# ---------------------------------------------------------------------------

_STREAMING_MODELS: dict[str, str] = {
    "anthropic": "claude-sonnet-4-20250514",
    "openai": "gpt-4o-mini",
}


class StreamingProbes:
    """Credential-gated streaming TTFT/TBT probes for Anthropic and OpenAI.

    Each probe method returns a ``BenchmarkResult`` with category
    ``llm_streaming`` and operation ``<provider>_streaming_ttft_tbt``,
    or None when credentials/SDK are unavailable.
    """

    def __init__(self, mode: str, timeout: float = 60.0):
        self.mode = mode
        self.iterations = 1 if mode == "quick" else 3
        self.timeout = timeout

    def _get_credentials(self) -> dict[str, str | None]:
        """Get credentials with PUP_ prefix per convention."""
        return {
            "anthropic": os.environ.get("PUP_ANTHROPIC_API_KEY")
            or os.environ.get("ANTHROPIC_API_KEY"),
            "openai": os.environ.get("PUP_OPENAI_API_KEY")
            or os.environ.get("OPENAI_API_KEY"),
        }

    # ---- Anthropic streaming probe ----

    def _probe_anthropic_streaming(self) -> BenchmarkResult | None:
        """Anthropic streaming TTFT/TBT probe using client.messages.stream()."""
        creds = self._get_credentials()
        api_key = creds.get("anthropic")
        if not api_key:
            return None

        try:
            import anthropic
        except ImportError:
            return None

        client = anthropic.Anthropic(api_key=api_key, timeout=self.timeout)
        fixture = get_fixture("short_v1")

        all_timestamps: list[list[float]] = []
        all_token_counts: list[int] = []
        all_chunk_counts: list[int] = []
        failures: list[dict[str, Any]] = []

        for i in range(self.iterations):
            try:
                timestamps: list[float] = []
                token_count = 0
                chunk_count = 0
                start = time.perf_counter()

                with client.messages.stream(
                    model=_STREAMING_MODELS["anthropic"],
                    max_tokens=50,
                    messages=[{"role": "user", "content": fixture.text}],
                ) as stream:
                    for event in stream:
                        chunk_count += 1
                        text = extract_anthropic_token_text(event)
                        if is_token_arrival(text):
                            ts = (time.perf_counter() - start) * 1000
                            timestamps.append(ts)
                            token_count += 1

                if timestamps:
                    all_timestamps.append(timestamps)
                    all_token_counts.append(token_count)
                    all_chunk_counts.append(chunk_count)
            except Exception as e:
                failures.append(
                    {"iteration": i, "error": str(e), "type": type(e).__name__}
                )

        if not all_timestamps:
            # All iterations failed or no token timestamps collected
            return None

        # Aggregate TTFTs across successful iterations for latency stats
        ttfts_ms = [ts[0] for ts in all_timestamps if ts]
        stats = LatencyStats.from_samples(ttfts_ms)

        # Aggregate inter-token gaps across all successful iterations
        # (never cross iteration boundaries)
        all_gaps: list[float] = []
        for ts_list in all_timestamps:
            all_gaps.extend(compute_inter_token_gaps(ts_list))
        combined_tbt_stats = LatencyStats.from_samples(all_gaps)

        # Build metadata from last iteration, override TBT with combined stats
        last_metrics = compute_streaming_metrics(
            all_timestamps[-1],
            model=_STREAMING_MODELS["anthropic"],
            prompt_id=fixture.prompt_id,
            token_count=all_token_counts[-1],
            chunk_count=all_chunk_counts[-1],
            failures=len(failures),
        )
        metadata = streaming_metrics_to_benchmark_metadata(last_metrics)
        metadata.update(
            {
                "tbt_mean_ms": combined_tbt_stats.mean_ms,
                "tbt_median_ms": combined_tbt_stats.median_ms,
                "tbt_p95_ms": combined_tbt_stats.p95_ms,
                "tbt_p99_ms": combined_tbt_stats.p99_ms,
                "successful_iterations": len(all_timestamps),
            }
        )
        successful = len(all_timestamps)

        return BenchmarkResult(
            category="llm_streaming",
            operation="anthropic_streaming_ttft_tbt",
            approach="live_api",
            latency_stats=stats,
            throughput_ops_per_sec=0,
            metadata=metadata,
            notes=(
                f"TTFT from last iteration; TBT aggregated across "
                f"{successful} successful iteration(s)."
                + (f" {len(failures)} failure(s)." if failures else "")
            ),
        )

    # ---- OpenAI streaming probe ----

    def _probe_openai_streaming(self) -> BenchmarkResult | None:
        """OpenAI streaming TTFT/TBT probe using stream=True."""
        creds = self._get_credentials()
        api_key = creds.get("openai")
        if not api_key:
            return None

        try:
            import openai
        except ImportError:
            return None

        client = openai.OpenAI(api_key=api_key, timeout=self.timeout)
        fixture = get_fixture("short_v1")

        all_timestamps: list[list[float]] = []
        all_token_counts: list[int] = []
        all_chunk_counts: list[int] = []
        failures: list[dict[str, Any]] = []

        for i in range(self.iterations):
            try:
                timestamps: list[float] = []
                token_count = 0
                chunk_count = 0
                start = time.perf_counter()

                stream = client.chat.completions.create(
                    model=_STREAMING_MODELS["openai"],
                    max_tokens=50,
                    messages=[{"role": "user", "content": fixture.text}],
                    stream=True,
                )
                try:
                    for chunk in stream:
                        chunk_count += 1
                        text = extract_openai_token_text(chunk)
                        if is_token_arrival(text):
                            ts = (time.perf_counter() - start) * 1000
                            timestamps.append(ts)
                            token_count += 1
                finally:
                    if hasattr(stream, "close"):
                        stream.close()

                if timestamps:
                    all_timestamps.append(timestamps)
                    all_token_counts.append(token_count)
                    all_chunk_counts.append(chunk_count)
            except Exception as e:
                failures.append(
                    {"iteration": i, "error": str(e), "type": type(e).__name__}
                )

        if not all_timestamps:
            return None

        ttfts_ms = [ts[0] for ts in all_timestamps if ts]
        stats = LatencyStats.from_samples(ttfts_ms)

        # Aggregate inter-token gaps across all successful iterations
        all_gaps: list[float] = []
        for ts_list in all_timestamps:
            all_gaps.extend(compute_inter_token_gaps(ts_list))
        combined_tbt_stats = LatencyStats.from_samples(all_gaps)

        # Build metadata from last iteration, override TBT with combined stats
        last_metrics = compute_streaming_metrics(
            all_timestamps[-1],
            model=_STREAMING_MODELS["openai"],
            prompt_id=fixture.prompt_id,
            token_count=all_token_counts[-1],
            chunk_count=all_chunk_counts[-1],
            failures=len(failures),
        )
        metadata = streaming_metrics_to_benchmark_metadata(last_metrics)
        metadata.update(
            {
                "tbt_mean_ms": combined_tbt_stats.mean_ms,
                "tbt_median_ms": combined_tbt_stats.median_ms,
                "tbt_p95_ms": combined_tbt_stats.p95_ms,
                "tbt_p99_ms": combined_tbt_stats.p99_ms,
                "successful_iterations": len(all_timestamps),
            }
        )
        successful = len(all_timestamps)

        return BenchmarkResult(
            category="llm_streaming",
            operation="openai_streaming_ttft_tbt",
            approach="live_api",
            latency_stats=stats,
            throughput_ops_per_sec=0,
            metadata=metadata,
            notes=(
                f"TTFT from last iteration; TBT aggregated across "
                f"{successful} successful iteration(s)."
                + (f" {len(failures)} failure(s)." if failures else "")
            ),
        )

    # ---- Runner ----

    def run_all(self) -> tuple[list[BenchmarkResult], list[str]]:
        """Run all streaming probes.

        Returns:
            Tuple of (results, not_implemented_list).
        """
        results: list[BenchmarkResult] = []
        not_implemented: list[str] = []

        creds = self._get_credentials()
        has_creds = bool(creds.get("anthropic") or creds.get("openai"))

        print("\n### LLM Streaming TTFT/TBT Benchmarks")
        print("-" * 60)

        if not has_creds:
            print("\n⚠ LLM streaming benchmarks NOT IMPLEMENTED - No credentials found")
            print("   Required: PUP_ANTHROPIC_API_KEY or PUP_OPENAI_API_KEY")
            not_implemented.append("llm_streaming_no_credentials")
            return results, not_implemented

        # Try Anthropic streaming
        if creds.get("anthropic"):
            print(
                f"\nProbing Anthropic streaming ({_STREAMING_MODELS['anthropic']})..."
            )
            result = self._probe_anthropic_streaming()
            if result:
                results.append(result)
                if result.latency_stats.samples > 0:
                    print(f"  ✓ TTFT: mean={result.latency_stats.mean_ms:.1f}ms")
                else:
                    print("  ✗ All iterations failed")
            else:
                print("  ✗ Failed (check API key or anthropic SDK)")
                not_implemented.append("anthropic_streaming_probe_failed")

        # Try OpenAI streaming
        if creds.get("openai"):
            print(f"\nProbing OpenAI streaming ({_STREAMING_MODELS['openai']})...")
            result = self._probe_openai_streaming()
            if result:
                results.append(result)
                if result.latency_stats.samples > 0:
                    print(f"  ✓ TTFT: mean={result.latency_stats.mean_ms:.1f}ms")
                else:
                    print("  ✗ All iterations failed")
            else:
                print("  ✗ Failed (check API key or openai SDK)")
                not_implemented.append("openai_streaming_probe_failed")

        if not results:
            not_implemented.append("llm_streaming_all_probes_failed")

        return results, not_implemented
