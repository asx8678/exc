"""Offline self-tests for streaming fixtures and metrics (no pytest, no network).

Split from self_test.py to keep the original file from growing needlessly.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
from scripts.bench_baseline.models import BenchmarkResult, LatencyStats
from scripts.bench_baseline.streaming import (
    compute_inter_token_gaps,
    compute_streaming_metrics,
    streaming_metrics_to_benchmark_metadata,
)
from scripts.bench_baseline.streaming_fixtures import (
    FIXTURES,
    MEDIUM,
    SHORT,
    all_fixture_ids,
    get_fixture,
)

# ---------------------------------------------------------------------------
# Streaming fixtures tests
# ---------------------------------------------------------------------------


class TestStreamingPromptFixture(unittest.TestCase):
    """Offline tests for streaming prompt fixtures."""

    def test_short_fixture_fields(self):
        """SHORT fixture must have stable prompt_id and non-empty text."""
        self.assertEqual(SHORT.prompt_id, "short_v1")
        self.assertTrue(len(SHORT.text) > 0)
        self.assertTrue(SHORT.expected_min_tokens > 0)

    def test_medium_fixture_fields(self):
        """MEDIUM fixture must have stable prompt_id and non-empty text."""
        self.assertEqual(MEDIUM.prompt_id, "medium_v1")
        self.assertTrue(len(MEDIUM.text) > 0)
        self.assertTrue(MEDIUM.expected_min_tokens > SHORT.expected_min_tokens)

    def test_fixtures_registry_contains_all(self):
        """FIXTURES registry must contain SHORT and MEDIUM."""
        self.assertIn(SHORT.prompt_id, FIXTURES)
        self.assertIn(MEDIUM.prompt_id, FIXTURES)

    def test_all_fixture_ids_sorted(self):
        """all_fixture_ids() must return sorted list."""
        ids = all_fixture_ids()
        self.assertEqual(ids, sorted(ids))
        self.assertIn(SHORT.prompt_id, ids)
        self.assertIn(MEDIUM.prompt_id, ids)

    def test_get_fixture_lookup(self):
        """get_fixture() must return the correct StreamingPrompt."""
        fixture = get_fixture("short_v1")
        self.assertIs(fixture, SHORT)

    def test_get_fixture_unknown_raises(self):
        """get_fixture() with unknown id must raise KeyError."""
        with self.assertRaises(KeyError):
            get_fixture("nonexistent_v99")

    def test_fixtures_are_frozen(self):
        """StreamingPrompt must be frozen (immutable)."""
        with self.assertRaises(AttributeError):
            SHORT.text = "mutated"  # type: ignore[misc]

    def test_fixtures_deterministic_text(self):
        """Same prompt_id must always yield the same text."""
        fixture = get_fixture("short_v1")
        self.assertEqual(fixture.text, SHORT.text)

    def test_no_network_access(self):
        """Fixtures module must not import any network libraries."""
        import importlib

        mod = importlib.import_module("scripts.bench_baseline.streaming_fixtures")
        with open(mod.__file__) as f:
            source = f.read()
        for forbidden in ("requests", "httpx", "urllib", "socket", "aiohttp"):
            self.assertNotIn(
                f"import {forbidden}",
                source,
                f"streaming_fixtures must not import {forbidden}",
            )


class TestStreamingPromptIdStability(unittest.TestCase):
    """Invariants for fixture id format."""

    def test_prompt_id_format(self):
        """All prompt_ids must follow <name>_v<n> convention."""
        import re

        pattern = re.compile(r"^[a-z][a-z0-9]*_v\d+$")
        for fid in all_fixture_ids():
            self.assertRegex(
                fid,
                pattern,
                f"prompt_id '{fid}' must match <name>_v<n> convention",
            )

    def test_fixture_ids_unique(self):
        """All fixture ids in registry must be unique."""
        ids = all_fixture_ids()
        self.assertEqual(len(ids), len(set(ids)), "Duplicate fixture ids found")


# ---------------------------------------------------------------------------
# Streaming metrics tests
# ---------------------------------------------------------------------------


class TestComputeInterTokenGaps(unittest.TestCase):
    """Offline tests for inter-token gap computation."""

    def test_basic_gaps(self):
        """Gaps should be differences between consecutive timestamps."""
        timestamps = [100.0, 150.0, 210.0, 280.0]
        gaps = compute_inter_token_gaps(timestamps)
        self.assertEqual(gaps, [50.0, 60.0, 70.0])

    def test_two_timestamps_one_gap(self):
        """Two timestamps produce exactly one gap."""
        gaps = compute_inter_token_gaps([10.0, 25.0])
        self.assertEqual(gaps, [15.0])

    def test_single_timestamp_no_gaps(self):
        """Single timestamp produces no gaps (need >= 2)."""
        gaps = compute_inter_token_gaps([50.0])
        self.assertEqual(gaps, [])

    def test_empty_timestamps_no_gaps(self):
        """Empty input produces no gaps."""
        gaps = compute_inter_token_gaps([])
        self.assertEqual(gaps, [])

    def test_non_monotonic_clamped(self):
        """Non-monotonic timestamps must produce gaps clamped to 0."""
        # Second timestamp goes backwards
        gaps = compute_inter_token_gaps([100.0, 50.0, 150.0])
        self.assertEqual(gaps[0], 0.0)  # Clamped from -50
        self.assertEqual(gaps[1], 100.0)  # 150 - 50

    def test_zero_gaps(self):
        """Identical consecutive timestamps produce 0 gaps."""
        gaps = compute_inter_token_gaps([100.0, 100.0, 100.0])
        self.assertEqual(gaps, [0.0, 0.0])


class TestComputeStreamingMetrics(unittest.TestCase):
    """Offline tests for full streaming metrics computation."""

    def test_basic_metrics(self):
        """Normal timestamps produce correct TTFT and TBT stats."""
        # TTFT=100ms, gaps: 50, 60, 70
        timestamps = [100.0, 150.0, 210.0, 280.0]
        metrics = compute_streaming_metrics(
            timestamps,
            model="test-model",
            prompt_id="short_v1",
        )
        self.assertAlmostEqual(metrics.ttft_ms, 100.0)
        self.assertAlmostEqual(metrics.total_duration_ms, 280.0)
        self.assertEqual(metrics.token_count, 4)
        self.assertEqual(metrics.chunk_count, 4)
        self.assertEqual(metrics.model, "test-model")
        self.assertEqual(metrics.prompt_id, "short_v1")

        # TBT stats from gaps [50, 60, 70]
        self.assertAlmostEqual(metrics.tbt_stats.mean_ms, 60.0)
        self.assertAlmostEqual(metrics.tbt_stats.median_ms, 60.0)
        self.assertEqual(metrics.tbt_stats.samples, 3)

    def test_empty_timestamps_degenerate(self):
        """Empty timestamps produce zeroed degenerate metrics."""
        metrics = compute_streaming_metrics(
            [],
            model="test-model",
            prompt_id="short_v1",
        )
        self.assertEqual(metrics.ttft_ms, 0.0)
        self.assertEqual(metrics.total_duration_ms, 0.0)
        self.assertEqual(metrics.token_count, 0)
        self.assertEqual(metrics.chunk_count, 0)
        self.assertEqual(metrics.tbt_stats.samples, 0)

    def test_single_timestamp_no_tbt(self):
        """Single timestamp sets TTFT but produces no TBT gaps."""
        metrics = compute_streaming_metrics([200.0])
        self.assertAlmostEqual(metrics.ttft_ms, 200.0)
        self.assertAlmostEqual(metrics.total_duration_ms, 200.0)
        self.assertEqual(metrics.tbt_stats.samples, 0)

    def test_explicit_token_chunk_overrides(self):
        """token_count and chunk_count overrides should take precedence."""
        timestamps = [100.0, 150.0]
        metrics = compute_streaming_metrics(
            timestamps,
            token_count=50,
            chunk_count=2,
        )
        self.assertEqual(metrics.token_count, 50)
        self.assertEqual(metrics.chunk_count, 2)

    def test_failures_and_timeout_fields(self):
        """failures and timeout must be preserved in metrics."""
        metrics = compute_streaming_metrics(
            [100.0, 200.0],
            failures=2,
            timeout=True,
        )
        self.assertEqual(metrics.failures, 2)
        self.assertTrue(metrics.timeout)


class TestStreamingMetricsSchema(unittest.TestCase):
    """Schema/output shape invariants for StreamingMetrics."""

    def test_to_dict_keys(self):
        """to_dict() must produce expected keys matching metric_names."""
        timestamps = [100.0, 150.0, 210.0]
        metrics = compute_streaming_metrics(
            timestamps,
            model="claude-sonnet-4-20250514",
            prompt_id="short_v1",
        )
        d = metrics.to_dict()

        # Must include core streaming metric fields
        expected_keys = {
            "ttft_ms",
            "tbt_mean_ms",
            "tbt_median_ms",
            "tbt_p95_ms",
            "tbt_p99_ms",
            "total_duration_ms",
            "token_count",
            "chunk_count",
            "model",
            "prompt_id",
            "failures",
            "timeout",
            "metric_names",
        }
        self.assertEqual(set(d.keys()), expected_keys)

    def test_to_dict_json_serializable(self):
        """to_dict() output must be JSON-serializable."""
        timestamps = [100.0, 150.0, 210.0]
        metrics = compute_streaming_metrics(
            timestamps,
            model="test-model",
            prompt_id="short_v1",
        )
        json_str = json.dumps(metrics.to_dict())
        self.assertIn("ttft_ms", json_str)

    def test_metric_names_present(self):
        """metric_names must be a non-empty tuple of known metric fields."""
        timestamps = [50.0, 100.0]
        metrics = compute_streaming_metrics(timestamps)
        self.assertTrue(len(metrics.metric_names) > 0)
        self.assertIn("ttft_ms", metrics.metric_names)
        self.assertIn("tbt_mean_ms", metrics.metric_names)

    def test_metadata_helper_output(self):
        """streaming_metrics_to_benchmark_metadata must match to_dict."""
        timestamps = [80.0, 120.0, 170.0]
        metrics = compute_streaming_metrics(
            timestamps,
            model="gpt-4o-mini",
            prompt_id="medium_v1",
        )
        meta = streaming_metrics_to_benchmark_metadata(metrics)
        self.assertEqual(meta, metrics.to_dict())


class TestTTFTvsTTFBDistinction(unittest.TestCase):
    """Enforce that TTFT is clearly distinct from existing TTFB convention."""

    def test_ttft_not_called_ttfb(self):
        """StreamingMetrics field must be ttft_ms, not ttfb_ms."""
        metrics = compute_streaming_metrics([100.0, 200.0])
        d = metrics.to_dict()
        self.assertIn("ttft_ms", d)
        self.assertNotIn("ttfb_ms", d, "Use ttft_ms for streaming, not ttfb_ms")

    def test_existing_benchmark_result_ttfb_unchanged(self):
        """Existing BenchmarkResult TTFB operations must still work."""
        # Verify existing non-streaming path still works as before
        stats = LatencyStats.from_samples([100.0, 200.0, 300.0])
        result = BenchmarkResult(
            category="llm_latency",
            operation="anthropic_ttfb",
            approach="live_api",
            latency_stats=stats,
            throughput_ops_per_sec=0,
            metadata={"model": "claude-sonnet-4-20250514"},
            notes="Time to first block (approximates TTFT). Paid API call.",
        )
        self.assertEqual(result.operation, "anthropic_ttfb")
        # Streaming metrics should use ttft_ms, not interfere
        streaming = compute_streaming_metrics(
            [50.0, 80.0],
            model="claude-sonnet-4-20250514",
            prompt_id="short_v1",
        )
        self.assertAlmostEqual(streaming.ttft_ms, 50.0)


def load_streaming_tests() -> unittest.TestSuite:
    """Return a TestSuite with all streaming self-tests.

    Called by scripts/bench_baseline/self_test.py to include these tests
    in the unified ``--self-test`` run.

    Named ``load_streaming_tests`` (not ``load_tests``) to avoid the
    unittest ``load_tests`` protocol which expects a 3-arg signature.
    """
    loader = unittest.TestLoader()
    return loader.loadTestsFromModule(sys.modules[__name__])


if __name__ == "__main__":
    unittest.main()
