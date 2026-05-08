"""Event backlog for callbacks fired before listeners register.

During plugin startup, callbacks may fire for phases that have no listeners
yet (because the plugin that registers the listener hasn't loaded). This
module buffers those calls and replays them once listeners are available.

Inspired by Gemini CLI's CoreEventEmitter._emitOrQueue() pattern.

Thread-safety: All mutable state is protected by _backlog_lock for
free-threaded Python (no-GIL) compatibility.
"""

import threading
from collections import deque

# Lazy-import PhaseType to avoid circular deps at module scope
_MAX_BACKLOG_PER_PHASE = 100

# Lock protecting all mutable module state for free-threaded Python
_backlog_lock = threading.Lock()

# phase -> deque of (args_tuple, kwargs_dict) that were fired with no listeners
_backlog: dict[str, deque[tuple[tuple, dict]]] = {}

# Track phases that have ever had a listener registered (for early-exit optimization)
# This is populated by callbacks.py when callbacks are registered
_had_listener: set[str] = set()

# Phases that commonly have late-registered listeners during plugin bootstrap.
# Always buffer these even if no listener exists yet - a plugin might load later.
# This is required for the backlog replay pattern to work during startup.
_ALWAYS_BUFFER_PHASES: frozenset[str] = frozenset(
    {
        "startup",
        "shutdown",
        "invoke_agent",
        "agent_run_start",
        "agent_run_end",
        "agent_exception",
        "custom_command",
        "custom_command_help",
        "stream_event",
        "message_history_processor_start",
        "message_history_processor_end",
    }
)


def buffer_event(phase: str, args: tuple, kwargs: dict) -> bool:
    """Buffer an event that had no listeners when fired.

    Returns True if event was buffered, False if skipped to save memory.
    """
    with _backlog_lock:
        # Early exit optimization: if no listener was ever registered for this phase,
        # AND it's not a commonly-used bootstrap phase, don't waste memory buffering
        # events that will likely never be consumed.
        if phase not in _had_listener and phase not in _ALWAYS_BUFFER_PHASES:
            return False

        buf = _backlog.get(phase)
        if buf is None:
            buf = deque(maxlen=_MAX_BACKLOG_PER_PHASE)
            _backlog[phase] = buf
        buf.append((args, kwargs))
        return True


def mark_phase_as_having_listener(phase: str) -> None:
    """Mark a phase as having had a listener registered.

    Called by callbacks.py when a callback is registered.
    """
    with _backlog_lock:
        _had_listener.add(phase)


def drain_backlog(phase: str) -> list[tuple[tuple, dict]]:
    """Pop and return all buffered events for *phase*."""
    with _backlog_lock:
        buf = _backlog.pop(phase, None)
        if not buf:
            return []
        return list(buf)


def drain_all() -> dict[str, list[tuple[tuple, dict]]]:
    """Pop and return buffered events for every phase that has any."""
    with _backlog_lock:
        result = {p: list(events) for p, events in _backlog.items() if events}
        _backlog.clear()
        return result


def pending_count(phase: str | None = None) -> int:
    """Return number of buffered events, optionally filtered by phase."""
    with _backlog_lock:
        if phase is not None:
            return len(_backlog.get(phase, ()))
        return sum(len(v) for v in _backlog.values())


def clear(phase: str | None = None) -> None:
    """Clear buffered events."""
    with _backlog_lock:
        if phase is None:
            _backlog.clear()
        else:
            _backlog.pop(phase, None)
