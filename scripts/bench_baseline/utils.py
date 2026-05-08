"""Utility functions for benchmarking."""

from __future__ import annotations

import signal
import sys
import time
from typing import Any, Callable, Sequence

from .models import LatencyStats

# ---------------------------------------------------------------------------
# Environment-variable helpers
# ---------------------------------------------------------------------------

_TRUTHY = frozenset({"1", "true", "yes", "on"})
_FALSY = frozenset({"0", "false", "no", "off"})
_VALID_BOOLS = _TRUTHY | _FALSY


def parse_env_bool(name: str, raw: str | None) -> bool:
    """Parse a boolean environment variable with strict truthy/falsy values.

    Accepts (case-insensitive): 1/0, true/false, yes/no, on/off.
    Returns *default_val* when *raw* is ``None``.
    Exits with code 2 and a clear message for any other value.

    Args:
        name: Environment variable name (for error messages).
        raw: Raw string value from ``os.environ.get``, or ``None``.

    Returns:
        Parsed boolean value.
    """
    if raw is None:
        return False
    normalized = raw.strip().lower()
    if normalized in _TRUTHY:
        return True
    if normalized in _FALSY:
        return False
    print(
        f"Error: {name}={raw!r} is not a valid boolean. "
        f"Expected one of: {', '.join(sorted(_VALID_BOOLS))} (case-insensitive).",
        file=sys.stderr,
    )
    sys.exit(2)


def validate_env_choice(
    name: str, raw: str | None, choices: Sequence[str]
) -> str | None:
    """Validate an env-provided choice against allowed values.

    Returns *raw* unchanged when valid, ``None`` when *raw* is ``None``
    (caller should fall back to argparse default), and exits with code 2
    and a clear message for any value outside *choices*.

    Args:
        name: Environment variable name (for error messages).
        raw: Raw string value from ``os.environ.get``, or ``None``.
        choices: Allowed values.

    Returns:
        The validated string, or ``None``.
    """
    if raw is None:
        return None
    if raw not in choices:
        print(
            f"Error: {name}={raw!r} is not a valid choice. "
            f"Expected one of: {', '.join(choices)}.",
            file=sys.stderr,
        )
        sys.exit(2)
    return raw


# Signal-based timeout is only available on Unix (SIGALRM).
_HAS_SIGALRM = hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")


def _timeout_handler(signum: int, frame: Any) -> None:
    """SIGALRM handler that raises TimeoutError instead of killing the process."""
    raise TimeoutError("benchmark iteration timed out")


def time_function(
    func: Callable[[], Any],
    iterations: int,
    warmup: int = 0,
    timeout_sec: float = 30.0,
) -> tuple[list[float], list[dict[str, Any]]]:
    """Time a function over multiple iterations with warmup and timeout.

    Uses signal.setitimer (sub-second precision) with a proper SIGALRM handler
    on Unix. Saves and restores the previous signal handler and itimer after
    all iterations. Falls back to no-timeout on platforms without SIGALRM.

    Args:
        func: Function to time (should be callable with no args)
        iterations: Number of benchmark iterations
        warmup: Number of warmup iterations
        timeout_sec: Maximum seconds per iteration (0 to disable)

    Returns:
        Tuple of (successful_times_ms, failures) where failures is a list
        of dicts containing iteration number and error info.
    """
    failures: list[dict[str, Any]] = []
    times_ms: list[float] = []

    use_signal_timeout = _HAS_SIGALRM and timeout_sec > 0

    # Save previous signal handler/timer once, restore at the end
    old_handler: Any = None
    old_itimer: tuple[float, float] | None = None

    if use_signal_timeout:
        old_handler = signal.getsignal(signal.SIGALRM)
        # Save and clear any existing itimer so we don't corrupt it
        old_itimer = signal.setitimer(signal.ITIMER_REAL, 0, 0)
        try:
            signal.signal(signal.SIGALRM, _timeout_handler)
        except OSError, ValueError:
            # Can't install handler (e.g. non-main thread); fall back
            use_signal_timeout = False

    try:
        # Warmup (not timed, failures don't count)
        for _ in range(warmup):
            try:
                if use_signal_timeout:
                    signal.setitimer(signal.ITIMER_REAL, timeout_sec, 0)
                func()
            except TimeoutError:
                pass  # Warmup timeouts are OK
            except Exception:
                pass  # Warmup failures are OK
            finally:
                if use_signal_timeout:
                    signal.setitimer(signal.ITIMER_REAL, 0, 0)

        # Benchmark with timeout enforcement
        for i in range(iterations):
            start = time.perf_counter()
            try:
                if use_signal_timeout:
                    signal.setitimer(signal.ITIMER_REAL, timeout_sec, 0)
                func()
                if use_signal_timeout:
                    signal.setitimer(signal.ITIMER_REAL, 0, 0)
                end = time.perf_counter()
                times_ms.append((end - start) * 1000)
            except TimeoutError:
                failures.append(
                    {"iteration": i, "error": "timeout", "type": "TimeoutError"}
                )
            except Exception as e:
                failures.append(
                    {"iteration": i, "error": str(e), "type": type(e).__name__}
                )
            finally:
                if use_signal_timeout:
                    signal.setitimer(signal.ITIMER_REAL, 0, 0)
    finally:
        # Always restore previous signal state
        if use_signal_timeout and old_handler is not None:
            try:
                signal.signal(signal.SIGALRM, old_handler)
            except OSError, ValueError:
                pass  # Best-effort restore
        if use_signal_timeout and old_itimer is not None:
            try:
                if old_itimer != (0.0, 0.0):
                    signal.setitimer(signal.ITIMER_REAL, *old_itimer)
            except OSError, ValueError:
                pass  # Best-effort restore

    return times_ms, failures


def format_stats(stats: LatencyStats) -> str:
    """Format latency stats for display."""
    return (
        f"mean={stats.mean_ms:.3f}ms, median={stats.median_ms:.3f}ms, "
        f"p95={stats.p95_ms:.3f}ms, p99={stats.p99_ms:.3f}ms"
    )
