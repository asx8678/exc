from __future__ import annotations

import asyncio
import logging
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from code_puppy.config_paths import resolve_path, safe_atomic_write

logger = logging.getLogger(__name__)

"""Concurrency limiters for file operations and API calls.

This module provides configurable semaphores for controlling concurrent:
- File operations (read/write/edit)
- API calls (outbound model requests)
- Tool executions

Configuration is read from <active-home>/concurrency.toml with sensible defaults.
"""

# Default concurrency limits
DEFAULT_FILE_OPS_LIMIT = 4  # Max concurrent file read/write operations
DEFAULT_API_CALLS_LIMIT = 2  # Max concurrent outbound API requests
DEFAULT_TOOL_CALLS_LIMIT = 8  # Max concurrent tool executions


# Respects pup-ex isolation (ADR-003) — resolves under active home
def _config_path() -> Path:
    """Return the concurrency config path under the active home."""
    return resolve_path("concurrency.toml")


# Global semaphores (initialized lazily)
_file_ops_semaphore: TrackedSemaphore | None = None
_api_calls_semaphore: TrackedSemaphore | None = None
_tool_calls_semaphore: TrackedSemaphore | None = None

# Cached config
_cached_config: ConcurrencyConfig | None = None

# Lock for thread-safe semaphore initialization
_semaphore_init_lock = threading.Lock()

# Lock for thread-safe config initialization
_config_init_lock = threading.Lock()


class TrackedSemaphore:
    """Wrapper around asyncio.Semaphore that tracks value without private attribute access.

    This class provides a Pythonic way to access the current semaphore value
    for monitoring purposes, without relying on implementation details.
    """

    def __init__(self, value: int):
        self._semaphore = asyncio.Semaphore(value)
        self._initial_value = value
        # Thread-safe counter for monitoring (works in both sync and async contexts)
        self._counter_lock = threading.Lock()
        self._available = value

    async def acquire(self) -> None:
        """Acquire a slot from the semaphore."""
        await self._semaphore.acquire()
        with self._counter_lock:
            self._available -= 1

    def release(self) -> None:
        """Release a slot back to the semaphore."""
        self._semaphore.release()
        with self._counter_lock:
            self._available = min(self._available + 1, self._initial_value)

    @property
    def value(self) -> int:
        """Get the current number of available slots.

        Thread-safe. The actual semaphore value is managed
        internally by asyncio.Semaphore.
        """
        return max(0, self._available)

    def locked(self) -> bool:
        """Return True if semaphore is locked (no slots available)."""
        return self._semaphore.locked()


@dataclass(frozen=True)
class ConcurrencyConfig:
    """Configuration for concurrency limits."""

    file_ops_limit: int = DEFAULT_FILE_OPS_LIMIT
    api_calls_limit: int = DEFAULT_API_CALLS_LIMIT
    tool_calls_limit: int = DEFAULT_TOOL_CALLS_LIMIT

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ConcurrencyConfig":
        """Create config from dictionary with validation."""
        return cls(
            file_ops_limit=max(
                1, int(data.get("file_ops_limit", DEFAULT_FILE_OPS_LIMIT))
            ),
            api_calls_limit=max(
                1, int(data.get("api_calls_limit", DEFAULT_API_CALLS_LIMIT))
            ),
            tool_calls_limit=max(
                1, int(data.get("tool_calls_limit", DEFAULT_TOOL_CALLS_LIMIT))
            ),
        )


def _read_config() -> ConcurrencyConfig:
    """Read concurrency configuration from TOML file."""
    global _cached_config

    # Double-checked locking pattern for thread-safe lazy initialization
    if _cached_config is not None:
        return _cached_config

    with _config_init_lock:
        if _cached_config is not None:
            return _cached_config

        if not _config_path().exists():
            _cached_config = ConcurrencyConfig()
            return _cached_config

        try:
            import tomllib  # Python 3.11+

            with open(_config_path(), "rb") as fh:
                data = tomllib.load(fh)

            _cached_config = ConcurrencyConfig.from_dict(data.get("concurrency", {}))
            return _cached_config

        except Exception as exc:
            logger.warning(
                "Failed to read concurrency config %s: %s", _config_path(), exc
            )
            _cached_config = ConcurrencyConfig()
            return _cached_config


def _get_file_ops_semaphore() -> TrackedSemaphore:
    """Get or create the file operations semaphore."""
    global _file_ops_semaphore
    if _file_ops_semaphore is None:
        with _semaphore_init_lock:
            if _file_ops_semaphore is None:  # Double-checked locking
                config = _read_config()
                _file_ops_semaphore = TrackedSemaphore(config.file_ops_limit)
                logger.debug(
                    "File ops semaphore initialized with limit %d",
                    config.file_ops_limit,
                )
    return _file_ops_semaphore


def _get_api_calls_semaphore() -> TrackedSemaphore:
    """Get or create the API calls semaphore."""
    global _api_calls_semaphore
    if _api_calls_semaphore is None:
        with _semaphore_init_lock:
            if _api_calls_semaphore is None:  # Double-checked locking
                config = _read_config()
                _api_calls_semaphore = TrackedSemaphore(config.api_calls_limit)
                logger.debug(
                    "API calls semaphore initialized with limit %d",
                    config.api_calls_limit,
                )
    return _api_calls_semaphore


def _get_tool_calls_semaphore() -> TrackedSemaphore:
    """Get or create the tool calls semaphore."""
    global _tool_calls_semaphore
    if _tool_calls_semaphore is None:
        with _semaphore_init_lock:
            if _tool_calls_semaphore is None:  # Double-checked locking
                config = _read_config()
                _tool_calls_semaphore = TrackedSemaphore(config.tool_calls_limit)
                logger.debug(
                    "Tool calls semaphore initialized with limit %d",
                    config.tool_calls_limit,
                )
    return _tool_calls_semaphore


async def acquire_file_ops_slot() -> None:
    """Acquire a slot for file operations.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local semaphore.
    """
    # Try Elixir bridge first if connected
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            result = await call_elixir_concurrency(
                "concurrency.acquire", {"type": "file_ops"}
            )
            if result.get("status") == "ok":
                return
    except ImportError:
        pass

    # Fallback to local semaphore
    sem = _get_file_ops_semaphore()
    await sem.acquire()


def release_file_ops_slot() -> None:
    """Release a file operations slot.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).
    """
    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            # Fire-and-forget: don't wait for response, ignore errors
            import asyncio

            try:
                asyncio.create_task(
                    call_elixir_concurrency(
                        "concurrency.release", {"type": "file_ops"}, timeout=1.0
                    )
                )
            except Exception:
                pass  # Ignore errors for fire-and-forget
    except ImportError:
        pass

    sem = _get_file_ops_semaphore()
    sem.release()


async def acquire_api_call_slot() -> None:
    """Acquire a slot for API calls.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local semaphore.
    """
    # Try Elixir bridge first if connected
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            result = await call_elixir_concurrency(
                "concurrency.acquire", {"type": "api_calls"}
            )
            if result.get("status") == "ok":
                return
    except ImportError:
        pass

    # Fallback to local semaphore
    sem = _get_api_calls_semaphore()
    await sem.acquire()


def release_api_call_slot() -> None:
    """Release an API call slot.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).
    """
    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            import asyncio

            try:
                asyncio.create_task(
                    call_elixir_concurrency(
                        "concurrency.release", {"type": "api_calls"}, timeout=1.0
                    )
                )
            except Exception:
                pass
    except ImportError:
        pass

    sem = _get_api_calls_semaphore()
    sem.release()


async def acquire_tool_call_slot() -> None:
    """Acquire a slot for tool calls.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local semaphore.
    """
    # Try Elixir bridge first if connected
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            result = await call_elixir_concurrency(
                "concurrency.acquire", {"type": "tool_calls"}
            )
            if result.get("status") == "ok":
                return
    except ImportError:
        pass

    # Fallback to local semaphore
    sem = _get_tool_calls_semaphore()
    await sem.acquire()


def release_tool_call_slot() -> None:
    """Release a tool call slot.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).
    """
    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_concurrency,
            is_connected,
        )

        if is_connected():
            import asyncio

            try:
                asyncio.create_task(
                    call_elixir_concurrency(
                        "concurrency.release", {"type": "tool_calls"}, timeout=1.0
                    )
                )
            except Exception:
                pass
    except ImportError:
        pass

    sem = _get_tool_calls_semaphore()
    sem.release()


# Context managers for cleaner usage


class Limiter:
    """Generic context manager for concurrency limiting.

    Usage:
        async with Limiter(_get_file_ops_semaphore):
            # do file operation
            pass
    """

    def __init__(self, semaphore_getter):
        self._get_sem = semaphore_getter
        self._sem = None

    async def __aenter__(self):
        self._sem = self._get_sem()
        await self._sem.acquire()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self._sem:
            self._sem.release()
        return False


# Convenience factory functions for specific limiter types
def FileOpsLimiter():
    """Context manager for file operations concurrency limiting."""
    return Limiter(_get_file_ops_semaphore)


def ApiCallsLimiter():
    """Context manager for API calls concurrency limiting."""
    return Limiter(_get_api_calls_semaphore)


def ToolCallsLimiter():
    """Context manager for tool calls concurrency limiting."""
    return Limiter(_get_tool_calls_semaphore)


def get_concurrency_status() -> dict[str, int]:
    """Get current semaphore status (for monitoring)."""
    config = _read_config()
    return {
        "file_ops_limit": config.file_ops_limit,
        "file_ops_available": (
            _file_ops_semaphore.value if _file_ops_semaphore else config.file_ops_limit
        ),
        "api_calls_limit": config.api_calls_limit,
        "api_calls_available": (
            _api_calls_semaphore.value
            if _api_calls_semaphore
            else config.api_calls_limit
        ),
        "tool_calls_limit": config.tool_calls_limit,
        "tool_calls_available": (
            _tool_calls_semaphore.value
            if _tool_calls_semaphore
            else config.tool_calls_limit
        ),
    }


def reload_concurrency_config() -> None:
    """Reload concurrency configuration from disk."""
    global \
        _cached_config, \
        _file_ops_semaphore, \
        _api_calls_semaphore, \
        _tool_calls_semaphore

    _cached_config = None
    _file_ops_semaphore = None
    _api_calls_semaphore = None
    _tool_calls_semaphore = None

    # Force re-initialization
    _ = _get_file_ops_semaphore()
    _ = _get_api_calls_semaphore()
    _ = _get_tool_calls_semaphore()

    logger.info("Concurrency configuration reloaded")


def reset_semaphores_for_tests() -> None:
    """Reset the global semaphores for test isolation.

    Clears all semaphore instances and cached config so the next
    call to any semaphore getter re-initializes with fresh state.
    Acquires the semaphore init lock to ensure thread-safe reset.
    """
    global \
        _file_ops_semaphore, \
        _api_calls_semaphore, \
        _tool_calls_semaphore, \
        _cached_config

    with _semaphore_init_lock:
        _file_ops_semaphore = None
        _api_calls_semaphore = None
        _tool_calls_semaphore = None
        _cached_config = None


def create_default_config() -> str:
    """Create default configuration file content."""
    return """# Code Puppy Concurrency Configuration
# Adjust these values based on your system and API rate limits

[concurrency]
# Maximum concurrent file read/write operations
# Higher values speed up file analysis but use more disk I/O
file_ops_limit = 4

# Maximum concurrent outbound API requests
# Lower this if you're hitting rate limits from providers
api_calls_limit = 2

# Maximum concurrent tool executions (includes file ops + shell commands)
# This is a broader limit for all tool calls
tool_calls_limit = 8
"""


def ensure_config_file() -> Path:
    """Ensure the configuration file exists with defaults."""
    if not _config_path().exists():
        safe_atomic_write(_config_path(), create_default_config())
        logger.info("Created default concurrency config at %s", _config_path())
    return _config_path()
