"""Per-session history buffer for WebSocket history replay.

This module provides SessionHistoryBuffer, a thread-safe per-session event
buffer that enables seamless WebSocket client reconnection. When a client
disconnects and reconnects with the same session_id, events emitted while
offline are replayed before live streaming resumes.

Configuration:
    ws_history_maxlen: Maximum events per session (default: 200)
    ws_history_ttl_seconds: TTL for abandoned sessions (default: 3600 = 1 hour)

Example:
    >>> from code_puppy.messaging.history_buffer import get_history_buffer
    >>> buffer = get_history_buffer()
    >>> buffer.record("session-123", {"type": "agent_start", "data": {...}})
    >>> # On reconnect:
    >>> history = buffer.get_history("session-123")
    >>> for event in history:
    ... await websocket.send_json(event)
    >>> buffer.clear_session("session-123") # Cleanup on disconnect
    >>> buffer.cleanup_expired_sessions() # Or let TTL cleanup run
"""

import logging
import threading
import time
from collections import deque
from typing import Any

from code_puppy.config import get_ws_history_maxlen, get_ws_history_ttl_seconds

logger = logging.getLogger(__name__)


class SessionHistoryBuffer:
    """Thread-safe per-session event buffer for WebSocket history replay.

    Each session has its own fixed-size deque (maxlen). When full, oldest
    events are automatically evicted (O(1)). Thread-safe for concurrent
    record() calls from multiple threads.

    TTL Cleanup:
        Sessions that haven't been accessed (recorded to or retrieved from)
        within the TTL period are automatically removed by cleanup_expired_sessions().
        This prevents memory leaks from abandoned sessions.

    Attributes:
        _maxlen: Maximum events per session deque.
        _ttl_seconds: TTL for abandoned sessions.
        _history: Dict mapping session_id → deque of events.
        _last_access: Dict mapping session_id → last access timestamp.
        _lock: threading.Lock for thread-safe access.
    """

    __slots__ = ("_maxlen", "_ttl_seconds", "_history", "_last_access", "_lock")

    def __init__(
        self, maxlen: int | None = None, ttl_seconds: int | None = None
    ) -> None:
        """Initialize the history buffer.

        Args:
            maxlen: Max events per session. If None, uses ws_history_maxlen
                from config (default 200).
            ttl_seconds: TTL for abandoned sessions in seconds. If None,
                uses ws_history_ttl_seconds from config (default 3600 = 1 hour).
        """
        self._maxlen = maxlen if maxlen is not None else get_ws_history_maxlen()
        self._ttl_seconds = (
            ttl_seconds if ttl_seconds is not None else get_ws_history_ttl_seconds()
        )
        self._history: dict[str, deque[dict[str, Any]]] = {}
        self._last_access: dict[str, float] = {}
        self._lock = threading.Lock()

    def _try_elixir(self, method: str, params: dict) -> dict | None:
        """Try to call Elixir EventStore via bridge. Returns None if unavailable.

        Proxy reads to Elixir EventStore when bridge is connected.
        Falls back to local deque when Elixir is not available.
        """
        try:
            from code_puppy.plugins.elixir_bridge import call_method, is_connected

            if is_connected():
                return call_method(method, params, timeout=5.0)
        except ImportError, NotImplementedError, ConnectionError, TimeoutError:
            pass
        except Exception:
            pass
        return None

    def _update_access_time(self, session_id: str) -> None:
        """Update the last access time for a session.

        Must be called with _lock held.
        """
        self._last_access[session_id] = time.monotonic()

    def record(self, session_id: str, event: dict[str, Any]) -> None:
        """Record an event for a session.

        Thread-safe. Creates the session deque if needed. Updates access time.

        Args:
            session_id: The session identifier.
            event: JSON-serializable event dict. Should have 'type' and
                optionally 'timestamp', 'id' fields.
        """
        with self._lock:
            # Use dict.get() with sentinel pattern for atomic get-or-create
            session_deque = self._history.get(session_id)
            if session_deque is None:
                session_deque = deque(maxlen=self._maxlen)
                self._history[session_id] = session_deque
            session_deque.append(event)
            self._update_access_time(session_id)

    def get_history(self, session_id: str) -> list[dict[str, Any]]:
        """Get buffered events for a session (newest first).

        Returns a copy of the deque as a list. The list is ordered from
        oldest to newest (same as deque iteration order). Updates access time.

        Args:
            session_id: The session identifier.

        Returns:
            List of events for the session, or empty list if session unknown.
        """
        # Try Elixir EventStore first (richer data, cursor-based)
        elixir_result = self._try_elixir("history_get", {"session_id": session_id})
        if elixir_result is not None:
            return elixir_result.get("events", [])

        # Fall back to local deque
        with self._lock:
            session_deque = self._history.get(session_id)
            if session_deque is None:
                return []
            self._update_access_time(session_id)
            return list(session_deque)

    def clear_session(self, session_id: str) -> bool:
        """Clear history for a session and remove it.

        Call this when a WebSocket disconnects to prevent memory leaks.

        Args:
            session_id: The session identifier.

        Returns:
            True if session existed and was cleared, False if unknown.
        """
        with self._lock:
            if session_id in self._history:
                del self._history[session_id]
                self._last_access.pop(session_id, None)
                return True
            return False

    def clear_all(self) -> int:
        """Clear all session history (useful for testing).

        Returns:
            Number of sessions cleared.
        """
        with self._lock:
            count = len(self._history)
            self._history.clear()
            self._last_access.clear()
            return count

    def session_count(self) -> int:
        """Get number of active sessions with history.

        Returns:
            Count of sessions with buffered events.
        """
        with self._lock:
            return len(self._history)

    def cleanup_expired_sessions(self, custom_ttl: int | None = None) -> int:
        """Remove sessions that haven't been accessed within the TTL period.

        This prevents memory leaks from abandoned WebSocket sessions that
        were never explicitly cleared.

        Args:
            custom_ttl: Optional override for TTL in seconds. If None,
                uses the configured ttl_seconds.

        Returns:
            Number of sessions removed.
        """
        ttl = custom_ttl if custom_ttl is not None else self._ttl_seconds
        if ttl <= 0:
            # TTL disabled (0 or negative means no cleanup)
            return 0

        now = time.monotonic()
        expired_sessions: list[str] = []

        with self._lock:
            for session_id, last_access in self._last_access.items():
                if now - last_access > ttl:
                    expired_sessions.append(session_id)

            for session_id in expired_sessions:
                self._history.pop(session_id, None)
                self._last_access.pop(session_id, None)

        if expired_sessions:
            logger.debug(
                "SessionHistoryBuffer: cleaned up %d expired sessions",
                len(expired_sessions),
            )
        return len(expired_sessions)

    def get_session_last_access(self, session_id: str) -> float | None:
        """Get the last access timestamp for a session.

        Args:
            session_id: The session identifier.

        Returns:
            Last access timestamp (monotonic), or None if session unknown.
        """
        with self._lock:
            return self._last_access.get(session_id)

    def event_count(self, session_id: str) -> int:
        """Get number of buffered events for a session.

        Args:
            session_id: The session identifier.

        Returns:
            Event count, or 0 if session unknown.
        """
        with self._lock:
            session_deque = self._history.get(session_id)
            return len(session_deque) if session_deque else 0

    def has_session(self, session_id: str) -> bool:
        """Check if a session has history.

        Args:
            session_id: The session identifier.

        Returns:
            True if session exists with history.
        """
        with self._lock:
            return session_id in self._history


# =============================================================================
# Global Singleton
# =============================================================================

_global_buffer: SessionHistoryBuffer | None = None
_buffer_lock = threading.Lock()


def get_history_buffer() -> SessionHistoryBuffer:
    """Get or create the global SessionHistoryBuffer singleton.

    Thread-safe. Creates buffer on first call with config maxlen.

    Returns:
        The global SessionHistoryBuffer instance.
    """
    global _global_buffer

    if _global_buffer is None:
        with _buffer_lock:
            if _global_buffer is None:
                _global_buffer = SessionHistoryBuffer()
    return _global_buffer


def reset_history_buffer() -> None:
    """Reset the global history buffer (for testing).

    Warning: This loses all buffered history!
    """
    global _global_buffer

    with _buffer_lock:
        _global_buffer = None


def reset_global_buffer_for_tests() -> None:
    """Reset the global history buffer singleton for test isolation.

    Clears the instance so the next get_history_buffer() call re-initializes.
    Acquires the buffer lock to ensure thread-safe reset.
    """
    global _global_buffer

    with _buffer_lock:
        if _global_buffer is not None:
            # Clear all session data before releasing
            _global_buffer.clear_all()
        _global_buffer = None


# =============================================================================
# Export
# =============================================================================

__all__ = [
    "SessionHistoryBuffer",
    "get_history_buffer",
    "reset_history_buffer",
    "reset_global_buffer_for_tests",
]
