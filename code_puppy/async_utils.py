"""Shared async utilities for running coroutines from sync code.

This module provides a bridge between async and sync code,
used by tools and resilience utilities that need to execute
async code from synchronous contexts.
"""

import asyncio
import atexit
import functools
import logging
import os
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any

# Module-level logger for warn_once
_logger = logging.getLogger(__name__)

# Thread-safe storage for warn_once tracking
_warn_once_keys: set[str] = set()
_warn_once_lock = threading.Lock()


def warn_once(key: str, message: str, logger: logging.Logger | None = None) -> None:
    """Log a warning message only once per unique key.

    This prevents log spam from repeated warnings (e.g., missing OAuth tokens,
    MCP server failures) by tracking which keys have already been logged.

    Thread-safe for concurrent calls.

    Args:
        key: Unique identifier for this warning. Duplicate keys are suppressed.
        message: The warning message to log on first occurrence.
        logger: Optional logger to use. Falls back to module logger if None.

    Example:
        >>> warn_once("oauth_token_missing", "OAuth token not configured")
        >>> warn_once("oauth_token_missing", "OAuth token not configured")  # Silently ignored
    """
    with _warn_once_lock:
        if key in _warn_once_keys:
            return
        _warn_once_keys.add(key)

    log = logger or _logger
    log.warning(message)


def clear_warn_once_history() -> None:
    """Clear all warn_once tracking state.

    Useful for testing to reset state between test cases.
    """
    with _warn_once_lock:
        _warn_once_keys.clear()


@functools.lru_cache(maxsize=512)
def format_size(size_bytes: int) -> str:
    """Format byte size to human readable string (B, KB, MB, GB)."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024):.1f} GB"


# Bounded thread pool for running async code - prevents thread explosion under load.
# max_workers matches Python's ThreadPoolExecutor default: min(32, cpu_count + 4)
_executor: ThreadPoolExecutor | None = None
_executor_lock = threading.Lock()


def _get_executor() -> ThreadPoolExecutor:
    """Get or create the module-level ThreadPoolExecutor."""
    global _executor
    if _executor is None:
        with _executor_lock:
            if _executor is None:
                max_workers = min(32, (os.cpu_count() or 1) + 4)
                _executor = ThreadPoolExecutor(
                    max_workers=max_workers,
                    thread_name_prefix="async_utils_pool",
                )
    return _executor


def _shutdown_executor() -> None:
    """Gracefully shutdown the thread pool executor."""
    global _executor
    if _executor is not None:
        _executor.shutdown(wait=True)
        _executor = None


def _register_shutdown_callback() -> None:
    """Register executor shutdown with the app lifecycle system.

    Prefers the callbacks system for proper ordering during graceful shutdown.
    Falls back to atexit if the callbacks system is unavailable.
    """
    try:
        from code_puppy.callbacks import register_callback

        register_callback("shutdown", _shutdown_executor)
    except ImportError:
        # Callbacks system not available — fall back to atexit
        atexit.register(_shutdown_executor)


# Register with callbacks system (or atexit as fallback)
_register_shutdown_callback()


def _run_coro_in_thread(coro) -> Any:
    """Run a coroutine in a new event loop within the current thread."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()
        asyncio.set_event_loop(None)


def run_async_sync(coro) -> Any:
    """Run a coroutine in a background thread pool's event loop.

    Uses a bounded ThreadPoolExecutor to prevent thread explosion under load.
    Each worker thread creates, uses, and closes its own dedicated event loop.

    Args:
        coro: The coroutine to run

    Returns:
        The result of the coroutine
    """
    executor = _get_executor()
    future = executor.submit(_run_coro_in_thread, coro)
    return future.result()


class DebouncedQueue[T]:
    """Generic thread-safe debounced batch queue with per-key deduplication.

    Items added within the debounce window are batched together and flushed
    when the timer expires. Adding an item with the same key replaces the
    existing entry, ensuring only the latest value for each key is retained.

    The timer resets on each add() call, delaying the flush until the debounce
    interval passes with no new additions.

    Type-safe generic API allows storing any type T. Thread-safe for concurrent
    adds from multiple threads.

    Args:
        callback: Function called with list[T] when the queue is flushed
        interval_ms: Debounce interval in milliseconds
        daemon_timer: Whether the timer thread should be a daemon (default: True)

    Example:
        def on_flush(items: list[str]):
            print(f"Flushing: {items}")

        queue = DebouncedQueue[str](callback=on_flush, interval_ms=100)
        queue.add("key1", "value1")
        queue.add("key2", "value2")
        queue.add("key1", "value1_updated")  # Replaces first value1
        # After 100ms of inactivity: on_flush called with ["value1_updated", "value2"]
    """

    def __init__(
        self,
        callback: Callable[[list[T]], None],
        interval_ms: float,
        daemon_timer: bool = True,
    ) -> None:
        self._callback = callback
        self._interval_ms = interval_ms
        self._daemon_timer = daemon_timer
        self._lock = threading.Lock()
        self._items: dict[str, T] = {}
        self._timer: threading.Timer | None = None
        self._shutdown = False

        # Register with callbacks system for graceful shutdown
        self._register_shutdown()

    def _register_shutdown(self) -> None:
        """Register shutdown callback to flush remaining items."""
        try:
            from code_puppy.callbacks import register_callback

            register_callback("shutdown", self._on_shutdown)
        except ImportError:
            # Fallback to atexit if callbacks system not available
            atexit.register(self._on_shutdown)

    def _on_shutdown(self) -> None:
        """Flush remaining items on shutdown, invoking the callback."""
        with self._lock:
            self._shutdown = True
        self._flush_and_callback()

    def add(self, key: str, value: T) -> None:
        """Add an item with the given key.

        If an item with the same key exists, it is replaced with the new value.
        The debounce timer is reset, delaying the flush.

        Args:
            key: Unique identifier for this item
            value: The value to store (type T)
        """
        with self._lock:
            if self._shutdown:
                # Still store the item even if shutting down - will be flushed
                pass

            # Store/replace the item (deduplication)
            self._items[key] = value

            # Cancel existing timer
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

            # Start new timer
            self._timer = threading.Timer(
                self._interval_ms / 1000.0,  # Convert ms to seconds
                self._flush_and_callback,
            )
            self._timer.daemon = self._daemon_timer
            self._timer.start()

    def _flush_and_callback(self) -> None:
        """Internal flush that also acquires lock."""
        items = self._do_flush()
        if items:
            self._callback(items)

    def _do_flush(self) -> list[T]:
        """Atomically flush items and clear the queue."""
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
            items = list(self._items.values())
            self._items.clear()
            return items

    def flush(self) -> list[T]:
        """Force an immediate flush of all pending items.

        Returns:
            List of flushed items (values only, keys are internal)
        """
        items = self._do_flush()
        return items

    def pending_count(self) -> int:
        """Return the number of pending items.

        Returns:
            Number of items waiting to be flushed
        """
        with self._lock:
            return len(self._items)

    def is_empty(self) -> bool:
        """Check if the queue has no pending items.

        Returns:
            True if no items are pending, False otherwise
        """
        with self._lock:
            return len(self._items) == 0
