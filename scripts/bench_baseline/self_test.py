"""Lightweight offline self-tests using stdlib unittest (no pytest dependency)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
from scripts.bench_baseline.models import BenchmarkResult, BenchmarkSuite, LatencyStats
from scripts.bench_baseline.streaming_probes_self_test import (
    load_streaming_probes_tests as _load_streaming_probes_tests,
)
from scripts.bench_baseline.streaming_self_test import (
    load_streaming_tests as _load_streaming_tests,
)
from scripts.bench_baseline.utils import (
    format_stats,
    parse_env_bool,
    time_function,
    validate_env_choice,
)


class TestLatencyStats(unittest.TestCase):
    """Test statistical calculations."""

    def test_empty_samples(self):
        """Empty samples should return zero stats."""
        stats = LatencyStats.from_samples([])
        self.assertEqual(stats.mean_ms, 0.0)
        self.assertEqual(stats.samples, 0)

    def test_single_sample(self):
        """Single sample should have zero stdev."""
        stats = LatencyStats.from_samples([5.0])
        self.assertEqual(stats.mean_ms, 5.0)
        self.assertEqual(stats.stdev_ms, 0.0)
        self.assertEqual(stats.samples, 1)

    def test_percentiles(self):
        """Percentile calculation should be correct."""
        samples = list(range(100))  # 0-99
        stats = LatencyStats.from_samples(samples)
        self.assertEqual(stats.p95_ms, 94)  # 95th percentile of 0-99
        self.assertEqual(stats.p99_ms, 98)  # 99th percentile

    def test_stats_calculation(self):
        """Basic stats should calculate correctly."""
        samples = [1.0, 2.0, 3.0, 4.0, 5.0]
        stats = LatencyStats.from_samples(samples)
        self.assertAlmostEqual(stats.mean_ms, 3.0)
        self.assertEqual(stats.median_ms, 3.0)
        self.assertEqual(stats.min_ms, 1.0)
        self.assertEqual(stats.max_ms, 5.0)


class TestTimeFunction(unittest.TestCase):
    """Test timing function with timeout."""

    def test_basic_timing(self):
        """Basic timing should work."""
        import time

        def sleep_10ms():
            time.sleep(0.01)

        times, failures = time_function(
            sleep_10ms, iterations=3, warmup=1, timeout_sec=5.0
        )
        self.assertEqual(len(times), 3)
        self.assertEqual(len(failures), 0)
        # All times should be around 10ms
        for t in times:
            self.assertGreater(t, 5)  # At least 5ms
            self.assertLess(t, 100)  # Less than 100ms

    def test_failure_capture(self):
        """Failures should be captured, not swallowed."""

        def raise_error():
            raise ValueError("test error")

        times, failures = time_function(
            raise_error, iterations=3, warmup=0, timeout_sec=5.0
        )
        self.assertEqual(len(times), 0)
        self.assertEqual(len(failures), 3)
        for f in failures:
            self.assertEqual(f["type"], "ValueError")
            self.assertIn("test error", f["error"])

    def test_timeout_short_op_succeeds(self):
        """Quick operation with generous timeout should complete successfully."""
        import time

        def quick_op():
            time.sleep(0.01)

        times, failures = time_function(
            quick_op, iterations=1, warmup=0, timeout_sec=5.0
        )
        self.assertEqual(len(times), 1)
        self.assertEqual(len(failures), 0)

    @unittest.skipUnless(
        hasattr(__import__("signal"), "SIGALRM"),
        "SIGALRM not available on this platform",
    )
    def test_timeout_exceeded_returns_failure_not_exit(self):
        """Operation exceeding timeout should return failures, not kill process.

        signal.alarm() without a handler causes exit 142. With a proper
        handler the process survives and records a TimeoutError instead.
        """
        import time

        def slow_op():
            time.sleep(10)  # Way beyond the short timeout

        # Use a very short timeout (0.25s) to ensure the operation exceeds it
        times, failures = time_function(
            slow_op, iterations=3, warmup=0, timeout_sec=0.25
        )

        # All iterations should be recorded as timeout failures
        self.assertEqual(
            len(times), 0, "Expected no successful samples for timed-out ops"
        )
        self.assertEqual(len(failures), 3, "Expected 3 timeout failure records")
        for f in failures:
            self.assertEqual(f["type"], "TimeoutError")
            self.assertEqual(f["error"], "timeout")

    @unittest.skipUnless(
        hasattr(__import__("signal"), "SIGALRM"),
        "SIGALRM not available on this platform",
    )
    def test_timeout_survives_after_timeout(self):
        """Process must continue normally after a timeout \u2014 not exit 142."""
        import time

        def slow_op():
            time.sleep(10)

        def fast_op():
            time.sleep(0.01)

        # First: trigger a timeout
        times1, failures1 = time_function(
            slow_op, iterations=1, warmup=0, timeout_sec=0.25
        )
        self.assertEqual(len(times1), 0)
        self.assertEqual(len(failures1), 1)

        # Second: verify a normal operation still works after timeout
        times2, failures2 = time_function(
            fast_op, iterations=2, warmup=0, timeout_sec=5.0
        )
        self.assertEqual(len(times2), 2)
        self.assertEqual(len(failures2), 0)
        # Sanity: times are reasonable
        for t in times2:
            self.assertGreater(t, 5)


class TestBenchmarkSuite(unittest.TestCase):
    """Test suite serialization."""

    def test_to_dict(self):
        """Suite should serialize to dict."""
        suite = BenchmarkSuite(
            timestamp="2026-01-15T10:00:00Z",
            version="1.0.0",
            mode="test",
        )
        d = suite.to_dict()
        self.assertEqual(d["timestamp"], "2026-01-15T10:00:00Z")
        self.assertEqual(d["version"], "1.0.0")
        self.assertEqual(d["mode"], "test")
        self.assertEqual(d["results"], [])

    def test_add_result(self):
        """Should be able to add results."""
        suite = BenchmarkSuite(
            timestamp="2026-01-15T10:00:00Z",
            version="1.0.0",
            mode="test",
        )
        stats = LatencyStats.from_samples([1.0, 2.0, 3.0])
        result = BenchmarkResult(
            category="test",
            operation="test_op",
            approach="python",
            latency_stats=stats,
            throughput_ops_per_sec=100.0,
        )
        suite.add(result)
        self.assertEqual(len(suite.results), 1)

    def test_json_serialization(self):
        """Should be JSON serializable."""
        suite = BenchmarkSuite(
            timestamp="2026-01-15T10:00:00Z",
            version="1.0.0",
            mode="test",
        )
        stats = LatencyStats.from_samples([1.0, 2.0, 3.0])
        result = BenchmarkResult(
            category="test",
            operation="test_op",
            approach="python",
            latency_stats=stats,
            throughput_ops_per_sec=100.0,
            metadata={"key": "value"},
        )
        suite.add(result)
        suite.pending_benchmarks.append("pending_test")
        suite.not_implemented.append("not_impl_test")

        # Should serialize without error
        json_str = json.dumps(suite.to_dict())
        self.assertIn("test_op", json_str)
        self.assertIn("pending_test", json_str)
        self.assertIn("not_impl_test", json_str)


class TestFormatStats(unittest.TestCase):
    """Test stats formatting."""

    def test_format(self):
        """Should format stats nicely."""
        stats = LatencyStats.from_samples([1.0, 2.0, 3.0])
        formatted = format_stats(stats)
        self.assertIn("mean=2.0", formatted)
        self.assertIn("median=2.0", formatted)


class TestEnvBoolParsing(unittest.TestCase):
    """Test strict boolean environment-variable parsing."""

    # --- truthy values ---

    def test_quick_1_is_truthy(self):
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "1"))

    def test_quick_true_is_truthy(self):
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "true"))

    def test_quick_yes_is_truthy(self):
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "yes"))

    def test_quick_on_is_truthy(self):
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "on"))

    # --- falsy values ---

    def test_quick_0_is_falsy(self):
        """PUP_BENCH_QUICK=0 must be parsed as false (not truthy)."""
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "0"))

    def test_quick_false_is_falsy(self):
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "false"))

    def test_quick_no_is_falsy(self):
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "no"))

    def test_quick_off_is_falsy(self):
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "off"))

    # --- None (unset) ---

    def test_quick_none_returns_false(self):
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", None))

    # --- case-insensitive ---

    def test_quick_case_insensitive(self):
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "TRUE"))
        self.assertTrue(parse_env_bool("PUP_BENCH_QUICK", "Yes"))
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "FALSE"))
        self.assertFalse(parse_env_bool("PUP_BENCH_QUICK", "No"))

    # --- invalid values exit non-zero ---

    def test_invalid_quick_exits(self):
        """Invalid PUP_BENCH_QUICK value must exit non-zero with clear message."""
        with self.assertRaises(SystemExit) as ctx:
            parse_env_bool("PUP_BENCH_QUICK", "maybe")
        self.assertEqual(ctx.exception.code, 2)

    def test_empty_string_quick_exits(self):
        """Empty string is not a valid boolean and must exit."""
        with self.assertRaises(SystemExit) as ctx:
            parse_env_bool("PUP_BENCH_QUICK", "")
        self.assertEqual(ctx.exception.code, 2)


class TestEnvChoiceValidation(unittest.TestCase):
    """Test environment-variable category validation."""

    _CHOICES = ("all", "tools", "llm")

    def test_valid_choices_pass(self):
        for c in self._CHOICES:
            self.assertEqual(
                validate_env_choice("PUP_BENCH_CATEGORY", c, self._CHOICES), c
            )

    def test_none_returns_none(self):
        """Unset env var returns None so caller falls back to argparse default."""
        self.assertIsNone(
            validate_env_choice("PUP_BENCH_CATEGORY", None, self._CHOICES)
        )

    def test_invalid_category_exits(self):
        """PUP_BENCH_CATEGORY=bogus must exit non-zero with clear message."""
        with self.assertRaises(SystemExit) as ctx:
            validate_env_choice("PUP_BENCH_CATEGORY", "bogus", self._CHOICES)
        self.assertEqual(ctx.exception.code, 2)

    def test_typo_category_exits(self):
        """Near-miss category must also be rejected."""
        with self.assertRaises(SystemExit) as ctx:
            validate_env_choice("PUP_BENCH_CATEGORY", "tool", self._CHOICES)
        self.assertEqual(ctx.exception.code, 2)


class TestHarnessEnvIntegration(unittest.TestCase):
    """Integration tests: exercise actual harness with env vars via subprocess."""

    _HARNESS = str(Path(__file__).parent.parent / "bench_baseline_harness.py")
    # Vars to scrub from inherited env so parent leaks don't poison child
    _SCRUB_PREFIXES = ("PUP_BENCH_",)
    _SCRUB_EXACT = frozenset(
        {
            "PUP_ANTHROPIC_API_KEY",
            "PUP_OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
        }
    )

    def _build_sanitized_env(self, env_extra: dict[str, str]) -> dict[str, str]:
        """Build a sanitized env for subprocess tests.

        Strips PUP_BENCH_* and API-key variables from inherited env so
        parent's env cannot influence integration test assertions.
        Only variables explicitly passed in *env_extra* are included.
        Essential vars (PATH, HOME, UV cache dirs, etc.) are preserved.
        """
        env = os.environ.copy()
        # Remove PUP_BENCH_* prefix vars
        to_remove = [k for k in env if k.startswith(self._SCRUB_PREFIXES)]
        # Remove API key vars
        to_remove.extend(k for k in self._SCRUB_EXACT if k in env)
        for k in to_remove:
            del env[k]
        # Overlay explicit test env vars
        env.update(env_extra)
        return env

    def _run_harness(
        self, env_extra: dict[str, str], extra_args: list[str] | None = None
    ) -> subprocess.CompletedProcess[str]:  # type: ignore[type-arg]
        env = self._build_sanitized_env(env_extra)
        cmd = [sys.executable, self._HARNESS]
        if extra_args:
            cmd.extend(extra_args)
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )

    def test_quick_0_yields_full_mode(self):
        """PUP_BENCH_QUICK=0 must NOT report Mode: quick."""
        proc = self._run_harness({"PUP_BENCH_QUICK": "0"}, ["--category", "llm"])
        self.assertNotIn(
            "Mode: quick", proc.stdout, "PUP_BENCH_QUICK=0 must not enable quick mode"
        )
        self.assertIn("Mode: full", proc.stdout)

    def test_invalid_quick_exits_nonzero(self):
        """Invalid PUP_BENCH_QUICK must exit non-zero."""
        proc = self._run_harness({"PUP_BENCH_QUICK": "maybe"}, ["--category", "llm"])
        self.assertNotEqual(proc.returncode, 0, "Invalid PUP_BENCH_QUICK must fail")
        self.assertIn("not a valid boolean", proc.stderr)

    def test_invalid_category_exits_nonzero(self):
        """PUP_BENCH_CATEGORY=bogus must exit non-zero."""
        proc = self._run_harness({"PUP_BENCH_CATEGORY": "bogus"}, ["--quick"])
        self.assertNotEqual(proc.returncode, 0, "Invalid PUP_BENCH_CATEGORY must fail")
        self.assertIn("not a valid choice", proc.stderr)

    def test_json_output(self):
        """JSON output should be valid and readable."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            path = f.name

        try:
            suite = BenchmarkSuite(
                timestamp="2026-01-15T10:00:00Z",
                version="1.0.0",
                mode="test",
            )
            stats = LatencyStats.from_samples([1.0, 2.0, 3.0])
            result = BenchmarkResult(
                category="test",
                operation="test_op",
                approach="python",
                latency_stats=stats,
                throughput_ops_per_sec=100.0,
            )
            suite.add(result)

            # Write JSON
            with open(path, "w") as f:
                json.dump(suite.to_dict(), f, indent=2)

            # Read and validate
            with open(path) as f:
                data = json.load(f)

            self.assertEqual(data["version"], "1.0.0")
            self.assertEqual(len(data["results"]), 1)
        finally:
            Path(path).unlink(missing_ok=True)


class TestSubprocessEnvIsolation(TestHarnessEnvIntegration):
    """Verify parent env vars do NOT leak into subprocess integration tests.

    Inherits _build_sanitized_env / _run_harness from
    TestHarnessEnvIntegration.  Each test deliberately pollutes the current
    process's environment with bogus values, then asserts the subprocess
    is unaffected.
    """

    def test_parent_bogus_category_does_not_break_harness(self):
        """Parent PUP_BENCH_CATEGORY=bogus must not break subprocess harness.

        The --self-test path short-circuits before env validation, so
        it's naturally immune. The real danger is normal harness
        invocations. _build_sanitized_env scrubs the bogus value.
        """
        os.environ["PUP_BENCH_CATEGORY"] = "bogus"
        try:
            # --category llm with no API keys -> quick exit, no live LLM
            proc = self._run_harness({}, ["--category", "llm"])
            self.assertEqual(
                proc.returncode,
                0,
                f"Harness must succeed with parent PUP_BENCH_CATEGORY=bogus\n"
                f"stderr: {proc.stderr}\nstdout: {proc.stdout}",
            )
            # Child must see CLI arg, not crash on parent's bogus env
            self.assertIn("Category: llm", proc.stdout)
        finally:
            os.environ.pop("PUP_BENCH_CATEGORY", None)

    def test_parent_invalid_quick_does_not_break_harness(self):
        """Parent PUP_BENCH_QUICK=maybe must not break subprocess harness."""
        os.environ["PUP_BENCH_QUICK"] = "maybe"
        try:
            proc = self._run_harness({}, ["--category", "llm"])
            self.assertEqual(
                proc.returncode,
                0,
                f"Harness must succeed even with parent PUP_BENCH_QUICK=maybe\n"
                f"stderr: {proc.stderr}\nstdout: {proc.stdout}",
            )
            # The child must see 'full' mode (no --quick, no env var)
            self.assertIn("Mode: full", proc.stdout)
        finally:
            os.environ.pop("PUP_BENCH_QUICK", None)

    def test_parent_api_keys_not_inherited(self):
        """Parent API keys must not leak into subprocess env."""
        # Inject dummy API keys into parent env
        os.environ["PUP_ANTHROPIC_API_KEY"] = "dummy-ant"
        os.environ["PUP_OPENAI_API_KEY"] = "dummy-oai"
        os.environ["ANTHROPIC_API_KEY"] = "dummy-ant2"
        os.environ["OPENAI_API_KEY"] = "dummy-oai2"
        try:
            # Run harness with --category llm but NO keys in env_extra
            proc = self._run_harness({}, ["--category", "llm"])
            # Must NOT attempt live LLM — should report no credentials
            self.assertIn(
                "No credentials found",
                proc.stdout,
                "Parent API keys must not leak; LLM bench should report no creds",
            )
        finally:
            for k in self._SCRUB_EXACT:
                os.environ.pop(k, None)

    def test_explicit_api_key_overrides_scrub(self):
        """API keys explicitly passed in env_extra should reach the subprocess."""
        # This test verifies that explicit passing still works after scrub
        os.environ["PUP_ANTHROPIC_API_KEY"] = "parent-leak-key"
        try:
            # Pass a DIFFERENT key explicitly
            proc = self._run_harness(
                {"PUP_ANTHROPIC_API_KEY": "explicit-test-key"},
                ["--category", "llm"],
            )
            # The explicit key is passed, so harness should see credentials
            # (it may fail the API call, but it should not say "no credentials")
            self.assertNotIn(
                "No credentials found",
                proc.stdout,
                "Explicitly passed API key should not be scrubbed",
            )
        finally:
            os.environ.pop("PUP_ANTHROPIC_API_KEY", None)

    def test_sanitized_env_strips_bench_prefix(self):
        """_build_sanitized_env must strip all PUP_BENCH_* prefix vars."""
        _bench_vars = {
            "PUP_BENCH_QUICK": "maybe",
            "PUP_BENCH_CATEGORY": "bogus",
            "PUP_BENCH_OUTPUT": "/tmp/should-not-exist.json",
            "PUP_BENCH_FUTURE_VAR": "whatever",
        }
        os.environ.update(_bench_vars)
        try:
            env = self._build_sanitized_env({})
            for key in _bench_vars:
                self.assertNotIn(key, env, f"{key} must be scrubbed from sanitized env")
        finally:
            for k in _bench_vars:
                os.environ.pop(k, None)

    def test_sanitized_env_preserves_essentials(self):
        """_build_sanitized_env must preserve PATH, HOME, UV cache vars."""
        # Ensure at least one essential var exists in parent
        self.assertIn("PATH", os.environ, "PATH must exist in env")
        env = self._build_sanitized_env({})
        self.assertIn("PATH", env, "PATH must survive sanitization")
        if "HOME" in os.environ:
            self.assertIn("HOME", env, "HOME must survive sanitization")
        for uv_var in ("UV_CACHE_DIR", "UV_DATA_DIR", "UV_TOOL_DIR"):
            if uv_var in os.environ:
                self.assertIn(uv_var, env, f"{uv_var} must survive sanitization")


class TestPendingNotImplemented(unittest.TestCase):
    """Test pending vs not_implemented handling."""

    def test_pending_list(self):
        """Pending benchmarks should be tracked."""
        suite = BenchmarkSuite(
            timestamp="2026-01-15T10:00:00Z",
            version="1.0.0",
            mode="test",
        )
        suite.pending_benchmarks.append("llm_latency_credentials_needed")
        d = suite.to_dict()
        self.assertIn("llm_latency_credentials_needed", d["pending_benchmarks"])

    def test_not_implemented_list(self):
        """Not implemented should be tracked separately."""
        suite = BenchmarkSuite(
            timestamp="2026-01-15T10:00:00Z",
            version="1.0.0",
            mode="test",
        )
        suite.not_implemented.append("llm_latency_no_credentials")
        d = suite.to_dict()
        self.assertIn("llm_latency_no_credentials", d["not_implemented"])


def run_tests() -> int:
    """Run all self-tests including streaming tests. Returns 0 on success, 1 on failure."""
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    # Include streaming fixtures/metrics tests from the split module
    suite.addTest(_load_streaming_tests())
    # Include streaming probe extraction/TBT/credential tests
    suite.addTest(_load_streaming_probes_tests())
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_tests())
