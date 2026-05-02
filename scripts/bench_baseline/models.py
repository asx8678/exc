"""Data models for benchmark results."""

from __future__ import annotations

import statistics
from dataclasses import asdict, dataclass, field
from typing import Any


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
    def from_samples(cls, samples_ms: list[float]) -> "LatencyStats":
        """Calculate stats from millisecond samples."""
        if not samples_ms:
            return cls(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0)

        samples = sorted(samples_ms)
        n = len(samples)

        p95_idx = max(0, int(n * 0.95) - 1)
        p99_idx = max(0, int(n * 0.99) - 1)

        return cls(
            mean_ms=statistics.mean(samples),
            median_ms=statistics.median(samples),
            min_ms=samples[0],
            max_ms=samples[-1],
            p95_ms=samples[p95_idx],
            p99_ms=samples[p99_idx],
            stdev_ms=statistics.stdev(samples) if n > 1 else 0.0,
            samples=n,
        )


@dataclass
class BenchmarkResult:
    """Result of a single benchmark operation."""

    category: str
    operation: str
    approach: str  # "python" or "elixir"
    latency_stats: LatencyStats
    throughput_ops_per_sec: float
    metadata: dict[str, Any] = field(default_factory=dict)
    notes: str = ""


@dataclass
class BenchmarkSuite:
    """Complete benchmark suite results."""

    timestamp: str
    version: str
    mode: str
    results: list[BenchmarkResult] = field(default_factory=list)
    pending_benchmarks: list[str] = field(default_factory=list)
    not_implemented: list[str] = field(default_factory=list)
    failed_benchmarks: list[dict[str, Any]] = field(default_factory=list)

    def add(self, result: BenchmarkResult) -> None:
        self.results.append(result)

    def to_dict(self) -> dict[str, Any]:
        return {
            "timestamp": self.timestamp,
            "version": self.version,
            "mode": self.mode,
            "results": [asdict(r) for r in self.results],
            "pending_benchmarks": self.pending_benchmarks,
            "not_implemented": self.not_implemented,
            "failed_benchmarks": self.failed_benchmarks,
        }
