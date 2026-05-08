"""Thread-safe update debouncer.

Ported from plandex's stream_tui/debouncer.go. Use this anywhere you
want to rate-limit UI or log updates to avoid flicker or spam.

Usage:
    debouncer = Debouncer(min_interval_s=0.2)  # 5 Hz max
    if debouncer.should_update():
        render_frame()
"""

import threading
import time


class Debouncer:
    """Rate-limits updates to at most once every ``min_interval_s`` seconds.

    Thread-safe. Each call to :meth:`should_update` returns True only if
    enough time has passed since the last approved update.
    """

    __slots__ = ("_min_interval", "_last_update", "_pending", "_initialized", "_lock")

    def __init__(self, min_interval_s: float) -> None:
        if min_interval_s < 0:
            raise ValueError("min_interval_s must be non-negative")
        self._min_interval = float(min_interval_s)
        self._last_update: float = 0.0
        self._pending: bool = False
        self._initialized: bool = False
        self._lock = threading.Lock()

    def should_update(self) -> bool:
        """Return True iff at least ``min_interval_s`` seconds have passed.

        Records the new update time on success. If False, sets ``pending``
        so callers can check :meth:`has_pending` to detect skipped frames.

        The first call always returns True (tracks state via _initialized).
        """
        with self._lock:
            now = time.monotonic()
            # First call: always allow
            if not self._initialized:
                self._last_update = now
                self._initialized = True
                self._pending = False
                return True
            if now - self._last_update < self._min_interval:
                self._pending = True
                return False
            self._last_update = now
            self._pending = False
            return True

    def has_pending(self) -> bool:
        """Return True if at least one call to should_update was rejected since the last approval."""
        with self._lock:
            return self._pending

    def reset(self) -> None:
        """Reset internal state (useful in tests)."""
        with self._lock:
            self._last_update = 0.0
            self._pending = False
            self._initialized = False
