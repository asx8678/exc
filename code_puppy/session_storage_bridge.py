"""Bridge to Elixir session storage.

This module provides the bridge between Python session_storage.py and
Elixir Ecto-backed session storage. It uses ElixirTransport when available
and falls back to the legacy file-based implementation.

(code_puppy-ctj.1) Extended with terminal session tracking methods that
route through SessionStorage.Store (ETS + PubSub + SQLite) for crash
survivability and real-time notifications.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

# Global transport instance (lazy-loaded)
_transport = None
_transport_available: bool | None = None


def _get_transport():
    """Get or create the ElixirTransport instance."""
    global _transport, _transport_available

    if _transport_available is None:
        try:
            from code_puppy.elixir_transport import ElixirTransport

            _transport = ElixirTransport()
            _transport.start()
            _transport_available = True
            logger.info("Session storage bridge initialized (Elixir transport)")
        except Exception as exc:
            _transport_available = False
            _transport = None
            logger.warning(
                "Elixir transport unavailable for session storage: %s. "
                "Falling back to file-based storage.",
                exc,
            )

    return _transport


def is_available() -> bool:
    """Check if the Elixir bridge is available."""
    transport = _get_transport()
    return transport is not None


def shutdown():
    """Shutdown the transport connection."""
    global _transport, _transport_available

    if _transport is not None:
        try:
            _transport.stop()
        except Exception as exc:
            logger.warning("Error stopping session storage bridge: %s", exc)
        finally:
            _transport = None
            _transport_available = None


def save_session(
    name: str,
    history: list[dict[str, Any]],
    compacted_hashes: list[str] | None = None,
    total_tokens: int = 0,
    auto_saved: bool = False,
    timestamp: str | None = None,
    has_terminal: bool = False,
    terminal_meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Save session via Elixir bridge.

    (code_puppy-ctj.1 fix) Now accepts has_terminal and terminal_meta
    parameters and forwards them to transport.session_save, matching
    the session_storage.py call site and elixir_transport.py signature.
    """
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_save(
        name=name,
        history=history,
        compacted_hashes=compacted_hashes,
        total_tokens=total_tokens,
        auto_saved=auto_saved,
        timestamp=timestamp,
        has_terminal=has_terminal,
        terminal_meta=terminal_meta,
    )


def load_session(name: str) -> dict[str, Any]:
    """Load session via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_load(name=name)


def load_session_full(name: str) -> dict[str, Any]:
    """Load session with metadata via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_load_full(name=name)


def list_sessions() -> list[str]:
    """List sessions via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_list()


def list_sessions_with_metadata() -> list[dict[str, Any]]:
    """List sessions with metadata via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_list_with_metadata()


def delete_session(name: str) -> bool:
    """Delete session via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_delete(name=name)


def cleanup_sessions(max_sessions: int = 10) -> list[str]:
    """Cleanup sessions via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_cleanup(max_sessions=max_sessions)


def session_exists(name: str) -> bool:
    """Check session exists via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_exists(name=name)


def session_count() -> int:
    """Get session count via Elixir bridge."""
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_count()


def register_terminal(
    name: str,
    session_id: str | None = None,
    cols: int = 80,
    rows: int = 24,
    shell: str | None = None,
) -> dict[str, Any]:
    """Register a terminal session for crash recovery tracking.

    (code_puppy-ctj.1) Records terminal metadata so that on crash/restart,
    the Elixir SessionStorage.TerminalRecovery module can attempt to
    recreate the PTY session. Durably persists to SQLite.

    Args:
        name: Session name (used as the storage key).
        session_id: Terminal session identifier (defaults to name).
        cols: Terminal width in columns.
        rows: Terminal height in rows.
        shell: Shell executable path.

    Returns:
        Dict with "registered" flag and session name, or error dict.
    """
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_register_terminal(
        name=name,
        session_id=session_id or name,
        cols=cols,
        rows=rows,
        shell=shell,
    )


def unregister_terminal(name: str) -> dict[str, Any]:
    """Unregister a terminal session from crash recovery tracking.

    (code_puppy-ctj.1) Called when a terminal session is closed gracefully.
    Durably clears terminal metadata from SQLite.

    Args:
        name: Session name to unregister.

    Returns:
        Dict with "unregistered" flag and session name, or error dict.
    """
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_unregister_terminal(name=name)


def list_terminals() -> list[dict[str, Any]]:
    """List all tracked terminal sessions.

    (code_puppy-ctj.1) Returns terminal metadata for crash recovery
    diagnostics.

    Returns:
        List of terminal metadata dicts.
    """
    transport = _get_transport()
    if transport is None:
        raise RuntimeError("Elixir transport not available")

    return transport.session_list_terminals()
