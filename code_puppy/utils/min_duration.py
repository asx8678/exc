"""Minimum-duration helpers for UX pacing.

Adopted from plandex's ``cli/utils/utils.go`` ``EnsureMinDuration`` pattern.
Prevents sub-second UI elements (spinners, status indicators) from flashing
so briefly they look like rendering glitches.

Usage::

    start = time.monotonic()
    # ... do some fast operation ...
    await ensure_min_duration_async(start, 0.35)   # async variant
    ensure_min_duration(start, 0.35)                # sync variant

Or as a context manager::

    async with MinDurationContext(0.35):
        # ... operation completes in 0.05 s → sleeps 0.30 s extra
        pass
"""

import asyncio
import time

__all__ = [
    "ensure_min_duration",
    "ensure_min_duration_async",
    "MinDurationContext",
    "SPINNER_MIN_DURATION_WITH_MSG",
    "SPINNER_MIN_DURATION_NO_MSG",
]

# Default minimum durations matching plandex's spinner timing.
# With a message: 700 ms so the user can read it.
# Without a message: 350 ms so the frame doesn't flash.
SPINNER_MIN_DURATION_WITH_MSG: float = 0.70
SPINNER_MIN_DURATION_NO_MSG: float = 0.35


def ensure_min_duration(start: float, min_seconds: float) -> None:
    """Block (synchronously) until at least *min_seconds* have elapsed.

    Does nothing if enough time has already passed.

    Args:
        start: Monotonic timestamp from ``time.monotonic()`` marking the
            start of the operation.
        min_seconds: Minimum wall-clock seconds that should have elapsed
            before this function returns.  Must be ≥ 0.
    """
    if min_seconds <= 0:
        return
    elapsed = time.monotonic() - start
    remaining = min_seconds - elapsed
    if remaining > 0:
        time.sleep(remaining)


async def ensure_min_duration_async(start: float, min_seconds: float) -> None:
    """Sleep (asynchronously) until at least *min_seconds* have elapsed.

    Does nothing if enough time has already passed.

    Args:
        start: Monotonic timestamp from ``time.monotonic()`` marking the
            start of the operation.
        min_seconds: Minimum wall-clock seconds that should have elapsed
            before this function returns.  Must be ≥ 0.
    """
    if min_seconds <= 0:
        return
    elapsed = time.monotonic() - start
    remaining = min_seconds - elapsed
    if remaining > 0:
        await asyncio.sleep(remaining)


class MinDurationContext:
    """Async context manager that enforces a minimum elapsed time.

    The timer starts on ``__aenter__`` and the remaining time (if any) is
    slept through on ``__aexit__``.

    Example::

        async with MinDurationContext(0.5):
            await fast_operation()  # takes 0.1 s → sleeps 0.4 s on exit
    """

    __slots__ = ("_min_seconds", "_start")

    def __init__(self, min_seconds: float) -> None:
        self._min_seconds = min_seconds
        self._start: float = 0.0

    async def __aenter__(self) -> "MinDurationContext":
        self._start = time.monotonic()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await ensure_min_duration_async(self._start, self._min_seconds)
