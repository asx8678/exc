"""Tool execution overhead benchmarks (offline filesystem primitives)."""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path
from typing import Any

from .models import BenchmarkResult, LatencyStats
from .utils import format_stats, time_function


class ToolOverheadBenchmarks:
    """Benchmark offline filesystem primitives (not full Code Puppy tool-path overhead).

    NOTE: These benchmarks measure raw filesystem operations (pathlib, rglob, read_text)
    to establish a baseline for comparison. They do NOT include:
    - Code Puppy tool wrapper overhead
    - Permission callbacks
    - Logging/telemetry
    - Elixir transport serialization overhead

    For full tool-path overhead, benchmarks would need to call actual tool functions
    via code_puppy.tools.file_operations (when safely available).
    """

    def __init__(self, mode: str):
        self.mode = mode
        self.warmup = 1 if mode == "quick" else 3
        self.iterations = 10 if mode == "quick" else 50
        self.timeout = 30.0  # Actually used now
        self.temp_dir: Path | None = None
        self.test_files: list[Path] = []

    def setup(self) -> None:
        """Create temporary test environment."""
        self.temp_dir = Path(tempfile.mkdtemp(prefix="code_puppy_bench_"))

        # Create test files of various sizes
        sizes = [(10, "small"), (100, "medium"), (1000, "large")]
        for lines, name in sizes:
            file_path = self.temp_dir / f"{name}.py"
            content = "\n\n".join(
                f'def function_{i}(x: int) -> int:\n    """Docstring for function {i}."""\n    return x + {i}'
                for i in range(lines)
            )
            file_path.write_text(content)
            self.test_files.append(file_path)

        # Create nested directory structure
        for i in range(5):
            nested = self.temp_dir / f"subdir_{i}"
            nested.mkdir()
            for j in range(3):
                (nested / f"file_{j}.py").write_text(f"# File {i}/{j}\nprint({j})")

    def teardown(self) -> None:
        """Clean up temporary test environment."""
        if self.temp_dir and self.temp_dir.exists():
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _try_import_file_ops(self) -> Any:
        """Import file operations module with fallback."""
        try:
            from code_puppy.tools import file_operations

            return file_operations
        except ImportError:
            return None

    def _try_import_elixir_bridge(self) -> Any:
        """Import Elixir bridge with fallback."""
        try:
            from code_puppy.plugins import elixir_bridge

            return elixir_bridge
        except ImportError:
            return None

    def _is_elixir_connected(self) -> bool:
        """Check if Elixir bridge is actually connected."""
        bridge = self._try_import_elixir_bridge()
        if bridge is None:
            return False
        try:
            return bool(bridge.is_connected())
        except Exception:
            return False

    def bench_list_files_offline(self) -> BenchmarkResult:
        """Benchmark offline list_files via pathlib (filesystem primitive baseline)."""
        assert self.temp_dir is not None

        def list_files():
            list(self.temp_dir.rglob("*.py"))

        times, failures = time_function(
            list_files, self.iterations, self.warmup, self.timeout
        )
        stats = LatencyStats.from_samples(times)

        notes = "Offline filesystem primitive (pathlib.rglob) - not full Code Puppy tool-path"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="list_files",
            approach="python_offline_primitive",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={
                "file_count": len(list(self.temp_dir.rglob("*.py"))),
                "failures": len(failures),
            },
            notes=notes,
        )

    def bench_list_files_elixir(self) -> BenchmarkResult | None:
        """Benchmark Elixir list_files via bridge (if connected)."""
        if not self._is_elixir_connected():
            return None

        bridge = self._try_import_elixir_bridge()
        assert self.temp_dir is not None and bridge is not None

        def list_files():
            bridge.list_files(str(self.temp_dir), recursive=True)

        times, failures = time_function(
            list_files, self.iterations, self.warmup, self.timeout
        )
        if not times:
            # All iterations failed - report as unavailable, not zero latency
            return None

        stats = LatencyStats.from_samples(times)

        notes = "Elixir bridge list_files"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="list_files",
            approach="elixir_bridge",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={"failures": len(failures)},
            notes=notes,
        )

    def bench_read_file_offline(self) -> BenchmarkResult:
        """Benchmark offline read_file via pathlib (filesystem primitive baseline)."""
        assert self.test_files
        test_file = self.test_files[1]  # medium file

        def read_file():
            test_file.read_text()

        times, failures = time_function(
            read_file, self.iterations, self.warmup, self.timeout
        )
        stats = LatencyStats.from_samples(times)

        notes = "Offline filesystem primitive (pathlib.read_text) - not full Code Puppy tool-path"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="read_file",
            approach="python_offline_primitive",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={"file_size_lines": 100, "failures": len(failures)},
            notes=notes,
        )

    def bench_read_file_elixir(self) -> BenchmarkResult | None:
        """Benchmark Elixir read_file via bridge (if connected)."""
        if not self._is_elixir_connected():
            return None

        bridge = self._try_import_elixir_bridge()
        assert self.test_files and bridge is not None
        test_file = str(self.test_files[1])

        def read_file():
            bridge.read_file(test_file)

        times, failures = time_function(
            read_file, self.iterations, self.warmup, self.timeout
        )
        if not times:
            return None

        stats = LatencyStats.from_samples(times)

        notes = "Elixir bridge read_file"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="read_file",
            approach="elixir_bridge",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={"failures": len(failures)},
            notes=notes,
        )

    def bench_grep_offline(self) -> BenchmarkResult:
        """Benchmark offline grep via Python loops (filesystem primitive baseline)."""
        assert self.temp_dir is not None

        def grep():
            for file_path in self.temp_dir.rglob("*.py"):
                try:
                    content = file_path.read_text()
                    for line in content.split("\n"):
                        if "def function_" in line:
                            pass
                except Exception:
                    pass

        iters = self.iterations // 2  # Fewer iterations, heavier op
        times, failures = time_function(grep, iters, self.warmup, self.timeout)
        stats = LatencyStats.from_samples(times)

        notes = "Offline filesystem primitive (Python loops) - not full Code Puppy tool-path"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="grep",
            approach="python_offline_primitive",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={
                "pattern": "def function_",
                "file_pattern": "*.py",
                "failures": len(failures),
            },
            notes=notes,
        )

    def bench_grep_elixir(self) -> BenchmarkResult | None:
        """Benchmark Elixir grep via bridge (if connected)."""
        if not self._is_elixir_connected():
            return None

        bridge = self._try_import_elixir_bridge()
        assert self.temp_dir is not None and bridge is not None

        def grep():
            bridge.grep("def function_", str(self.temp_dir))

        iters = self.iterations // 2
        times, failures = time_function(grep, iters, self.warmup, self.timeout)
        if not times:
            return None

        stats = LatencyStats.from_samples(times)

        notes = "Elixir bridge grep"
        if failures:
            notes += f"; {len(failures)} iterations failed"

        return BenchmarkResult(
            category="tool_execution",
            operation="grep",
            approach="elixir_bridge",
            latency_stats=stats,
            throughput_ops_per_sec=len(times) / (sum(times) / 1000) if times else 0,
            metadata={"failures": len(failures)},
            notes=notes,
        )

    def run_all(self) -> tuple[list[BenchmarkResult], list[dict[str, Any]]]:
        """Run all tool overhead benchmarks.

        Returns:
            Tuple of (results, failures) where failures are non-fatal errors.
        """
        results: list[BenchmarkResult] = []
        failures: list[dict[str, Any]] = []

        self.setup()
        try:
            print("\n### Tool Execution Overhead Benchmarks")
            print("-" * 60)
            print(
                "NOTE: These measure offline filesystem primitives, not full tool-path overhead."
            )
            print(
                "See approach='python_offline_primitive' vs 'elixir_bridge' in results."
            )
            print()

            # list_files
            print("\nRunning list_files benchmarks...")
            py_result = self.bench_list_files_offline()
            results.append(py_result)
            print(f"  Python (offline): {format_stats(py_result.latency_stats)}")

            ex_result = self.bench_list_files_elixir()
            if ex_result:
                results.append(ex_result)
                print(f"  Elixir (bridge):  {format_stats(ex_result.latency_stats)}")
                ratio = (
                    ex_result.latency_stats.mean_ms / py_result.latency_stats.mean_ms
                )
                print(
                    f"  Comparison: Elixir is {ratio:.2f}x {'slower' if ratio > 1 else 'faster'}"
                )
            else:
                print("  Elixir (bridge):  Not available (bridge not connected)")

            # read_file
            print("\nRunning read_file benchmarks...")
            py_result = self.bench_read_file_offline()
            results.append(py_result)
            print(f"  Python (offline): {format_stats(py_result.latency_stats)}")

            ex_result = self.bench_read_file_elixir()
            if ex_result:
                results.append(ex_result)
                print(f"  Elixir (bridge):  {format_stats(ex_result.latency_stats)}")
                ratio = (
                    ex_result.latency_stats.mean_ms / py_result.latency_stats.mean_ms
                )
                print(
                    f"  Comparison: Elixir is {ratio:.2f}x {'slower' if ratio > 1 else 'faster'}"
                )
            else:
                print("  Elixir (bridge):  Not available (bridge not connected)")

            # grep
            print("\nRunning grep benchmarks...")
            py_result = self.bench_grep_offline()
            results.append(py_result)
            print(f"  Python (offline): {format_stats(py_result.latency_stats)}")

            ex_result = self.bench_grep_elixir()
            if ex_result:
                results.append(ex_result)
                print(f"  Elixir (bridge):  {format_stats(ex_result.latency_stats)}")
                ratio = (
                    ex_result.latency_stats.mean_ms / py_result.latency_stats.mean_ms
                )
                print(
                    f"  Comparison: Elixir is {ratio:.2f}x {'slower' if ratio > 1 else 'faster'}"
                )
            else:
                print("  Elixir (bridge):  Not available (bridge not connected)")

        except Exception as e:
            # Broad catch at benchmark boundary: records failure type/message
            # explicitly so it is never reported as a successful latency sample.
            failures.append(
                {
                    "operation": "run_all_boundary",
                    "error": str(e),
                    "type": type(e).__name__,
                    "note": "broad exception catch at benchmark boundary",
                }
            )
            raise
        finally:
            self.teardown()

        return results, failures
