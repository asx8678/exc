"""Core schema and helpers for streaming LLM benchmark metrics.

Provides the data model and computation logic for streaming TTFT (time-to-
first-token) and TBT (time-between-tokens) metrics.  These are **distinct**
from the existing non-streaming TTFB (time-to-first-block) measured by the
credential-gated probe in ``llm.py``.

Key distinction:
  - TTFB ≈ wall-clock until the SDK returns the first complete block
    (non-streaming, single-shot).
  - TTFT = wall-clock until the *first token* arrives over a streaming
    connection.
  - TBT = inter-token latency computed from consecutive token arrival
    timestamps.

This module is offline-safe: it operates on timestamp arrays that live
streaming probes will collect and pass in. No network, no provider mocking.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .models import LatencyStats

# ---------------------------------------------------------------------------
# Streaming metrics schema
# ---------------------------------------------------------------------------

_METRIC_NAMES: tuple[str, ...] = (
    "ttft_ms",
    "tbt_mean_ms",
    "tbt_median_ms",
    "tbt_p95_ms",
    "tbt_p99_ms",
    "total_duration_ms",
    "token_count",
    "chunk_count",
)


@dataclass
class StreamingMetrics:
    """Streaming TTFT/TBT metrics for a single LLM streaming response.

    Attributes:
        ttft_ms: Time-to-first-token in milliseconds. This is the wall-clock
            time from request dispatch to arrival of the very first token.
            Distinct from non-streaming TTFB.
        tbt_stats: Statistical summary of inter-token gaps (time-between-
            tokens). Computed from consecutive token arrival timestamps.
        total_duration_ms: Wall-clock duration of the full streaming response,
            from request dispatch to last token received.
        token_count: Number of tokens received (provider-reported or
            approximated from chunk count).
        chunk_count: Number of streaming chunks/events received.
        model: Provider model identifier (e.g. "claude-sonnet-4-20250514").
        prompt_id: Fixture prompt id (references ``StreamingPrompt.prompt_id``).
        failures: Count of errors encountered during streaming.
        timeout: Whether the streaming response hit a timeout before
            completing.
        metric_names: Ordered list of metric field names included in
            ``to_dict()`` output, for schema discoverability.
    """

    ttft_ms: float
    tbt_stats: LatencyStats
    total_duration_ms: float
    token_count: int
    chunk_count: int
    model: str = ""
    prompt_id: str = ""
    failures: int = 0
    timeout: bool = False
    metric_names: tuple[str, ...] = field(default_factory=lambda: _METRIC_NAMES)

    def to_dict(self) -> dict[str, Any]:
        """Serialize to a flat dict suitable for JSON / BenchmarkResult.metadata."""
        return {
            "ttft_ms": self.ttft_ms,
            "tbt_mean_ms": self.tbt_stats.mean_ms,
            "tbt_median_ms": self.tbt_stats.median_ms,
            "tbt_p95_ms": self.tbt_stats.p95_ms,
            "tbt_p99_ms": self.tbt_stats.p99_ms,
            "total_duration_ms": self.total_duration_ms,
            "token_count": self.token_count,
            "chunk_count": self.chunk_count,
            "model": self.model,
            "prompt_id": self.prompt_id,
            "failures": self.failures,
            "timeout": self.timeout,
            "metric_names": list(self.metric_names),
        }


# ---------------------------------------------------------------------------
# Computation helpers
# ---------------------------------------------------------------------------


def compute_inter_token_gaps(timestamps_ms: list[float]) -> list[float]:
    """Compute inter-token gaps from ordered token arrival timestamps.

    Args:
        timestamps_ms: Monotonically increasing timestamps in milliseconds,
            one per received token/chunk.  Must contain at least 2 entries
            to produce gaps.

    Returns:
        List of gaps in ms between consecutive timestamps.  Length is
        ``len(timestamps_ms) - 1``.  Returns an empty list if fewer than
        2 timestamps are provided.
    """
    if len(timestamps_ms) < 2:
        return []
    gaps: list[float] = []
    for i in range(1, len(timestamps_ms)):
        gap = timestamps_ms[i] - timestamps_ms[i - 1]
        # Guard against non-monotonic input without crashing; clamp to 0.
        gaps.append(max(0.0, gap))
    return gaps


def compute_streaming_metrics(
    timestamps_ms: list[float],
    *,
    model: str = "",
    prompt_id: str = "",
    token_count: int | None = None,
    chunk_count: int | None = None,
    failures: int = 0,
    timeout: bool = False,
) -> StreamingMetrics:
    """Derive full streaming metrics from a list of token arrival timestamps.

    This is the primary entry point for future live probes: collect
    ``timestamps_ms`` during streaming, then call this to produce a
    ``StreamingMetrics`` instance.

    Args:
        timestamps_ms: Monotonically increasing timestamps in ms, starting
            from request dispatch (t=0).  The first entry is the TTFT.
        model: Provider model identifier.
        prompt_id: StreamingPrompt.prompt_id used for the request.
        token_count: Explicit token count override.  If None, defaults to
            ``len(timestamps_ms)`` (one timestamp per token).
        chunk_count: Explicit chunk count override.  If None, defaults to
            ``len(timestamps_ms)``.
        failures: Number of errors encountered during streaming.
        timeout: Whether the response hit a timeout.

    Returns:
        Populated ``StreamingMetrics`` instance.
    """
    if not timestamps_ms:
        # No tokens received — degenerate metrics
        return StreamingMetrics(
            ttft_ms=0.0,
            tbt_stats=LatencyStats.from_samples([]),
            total_duration_ms=0.0,
            token_count=token_count or 0,
            chunk_count=chunk_count or 0,
            model=model,
            prompt_id=prompt_id,
            failures=failures,
            timeout=timeout,
        )

    ttft_ms = timestamps_ms[0]
    total_duration_ms = timestamps_ms[-1]
    gaps = compute_inter_token_gaps(timestamps_ms)
    tbt_stats = LatencyStats.from_samples(gaps)

    return StreamingMetrics(
        ttft_ms=ttft_ms,
        tbt_stats=tbt_stats,
        total_duration_ms=total_duration_ms,
        token_count=token_count if token_count is not None else len(timestamps_ms),
        chunk_count=chunk_count if chunk_count is not None else len(timestamps_ms),
        model=model,
        prompt_id=prompt_id,
        failures=failures,
        timeout=timeout,
    )


def streaming_metrics_to_benchmark_metadata(
    metrics: StreamingMetrics,
) -> dict[str, Any]:
    """Convert StreamingMetrics to a dict suitable for BenchmarkResult.metadata.

    Future live probes should use this to populate the metadata field of a
    ``BenchmarkResult(category="llm_streaming", ...)``.
    """
    return metrics.to_dict()
