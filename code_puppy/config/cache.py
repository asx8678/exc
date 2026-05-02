"""Cache, session, and WebSocket configuration.

Mirrors ``CodePuppyControl.Config.Cache`` in the Elixir runtime.

Manages auto-save behavior, WebSocket history replay, frontend emitter
settings, and command history.

Config keys in puppy.cfg:

- ``auto_save_session`` — enable/disable auto-save (default true)
- ``max_saved_sessions`` — max sessions to keep (default 20)
- ``ws_history_maxlen`` — events to buffer per WS session (default 200)
- ``ws_history_ttl_seconds`` — TTL for abandoned WS sessions (default 3600)
"""

from __future__ import annotations

import datetime
import os

from code_puppy.config.loader import (
    _make_bool_getter,
    _make_int_getter,
    _registered_cache,
    get_value,
    set_config_value,
)
from code_puppy.config.paths import _path_autosave_dir, _path_command_history_file
from code_puppy.config_paths import assert_write_allowed as _assert_write_allowed

__all__ = [
    "get_auto_save_session",
    "set_auto_save_session",
    "get_max_saved_sessions",
    "set_max_saved_sessions",
    "get_ws_history_maxlen",
    "get_ws_history_ttl_seconds",
    "save_command_to_history",
    "initialize_command_history_file",
    "get_current_autosave_id",
    "rotate_autosave_id",
    "get_current_autosave_session_name",
    "set_current_autosave_from_session_name",
    "auto_save_session_if_enabled",
    "finalize_autosave_session",
]


# ---------------------------------------------------------------------------
# Auto-save
# ---------------------------------------------------------------------------


get_auto_save_session = _make_bool_getter(
    "auto_save_session",
    default=True,
    doc="Return True if auto-save is enabled (default True).",
)


def set_auto_save_session(enabled: bool) -> None:
    """Set auto_save_session."""
    set_config_value("auto_save_session", "true" if enabled else "false")


get_max_saved_sessions = _make_int_getter(
    "max_saved_sessions",
    default=20,
    min_val=0,
    doc="Return max sessions to keep (default 20).",
)


def set_max_saved_sessions(max_sessions: int) -> None:
    """Set max_saved_sessions."""
    set_config_value("max_saved_sessions", str(max_sessions))


# ---------------------------------------------------------------------------
# WebSocket history
# ---------------------------------------------------------------------------


@_registered_cache
def get_ws_history_maxlen() -> int:
    """Return max events to buffer per WS session for replay (default 200)."""
    val = get_value("ws_history_maxlen")
    if val is None:
        return 200
    try:
        return int(val)
    except ValueError:
        return 200


@_registered_cache
def get_ws_history_ttl_seconds() -> int:
    """Return TTL in seconds for abandoned WS session history (default 3600)."""
    val = get_value("ws_history_ttl_seconds")
    if val is None:
        return 3600
    try:
        return int(val)
    except ValueError:
        return 3600


# ---------------------------------------------------------------------------
# Command history
# ---------------------------------------------------------------------------


def initialize_command_history_file() -> None:
    """Ensure the command history file and directory exist."""
    history_file = _path_command_history_file()
    history_dir = os.path.dirname(str(history_file))
    if not os.path.exists(history_dir):
        _assert_write_allowed(history_dir, "initialize_command_history_file")
        os.makedirs(history_dir, mode=0o700, exist_ok=True)
    if not os.path.exists(str(history_file)):
        _assert_write_allowed(history_file, "initialize_command_history_file")
        with open(str(history_file), "w", encoding="utf-8") as f:
            f.write("# Code Puppy Command History\n")


def save_command_to_history(command: str) -> None:
    """Save a command to the history file with an ISO format timestamp."""
    try:
        timestamp = datetime.datetime.now().isoformat(timespec="seconds")

        try:
            command = command.encode("utf-8", errors="surrogatepass").decode(
                "utf-8", errors="replace"
            )
        except UnicodeEncodeError, UnicodeDecodeError:
            command = "".join(
                char if ord(char) < 0xD800 or ord(char) > 0xDFFF else "\ufffd"
                for char in command
            )

        history_file = _path_command_history_file()
        _assert_write_allowed(history_file, "save_command_to_history")
        with open(history_file, "a", encoding="utf-8", errors="surrogateescape") as f:
            f.write(f"\n# {timestamp}\n{command}\n")
    except Exception as e:
        from code_puppy.messaging import emit_error

        emit_error(f"Error saving command history: {str(e)}")


# ---------------------------------------------------------------------------
# Autosave session (delegates to runtime_state)
# ---------------------------------------------------------------------------


def get_current_autosave_id() -> str:
    """Get or create the current autosave session ID for this process."""
    from code_puppy import runtime_state

    return runtime_state.get_current_autosave_id()


def rotate_autosave_id() -> str:
    """Force a new autosave session ID and return it."""
    from code_puppy import runtime_state

    return runtime_state.rotate_autosave_id()


def get_current_autosave_session_name() -> str:
    """Return the full session name used for autosaves."""
    from code_puppy import runtime_state

    return runtime_state.get_current_autosave_session_name()


def set_current_autosave_from_session_name(session_name: str) -> str:
    """Set the current autosave ID based on a full session name."""
    from code_puppy import runtime_state

    return runtime_state.set_current_autosave_from_session_name(session_name)


def auto_save_session_if_enabled() -> bool:
    """Auto-save the current session if enabled. Non-blocking."""
    from code_puppy import runtime_state

    if not get_auto_save_session():
        return False

    try:
        from code_puppy.agents.agent_manager import get_current_agent
        from code_puppy.messaging import emit_info

        current_agent = get_current_agent()
        history = current_agent.get_message_history()
        if not history:
            return False

        from code_puppy.session_storage import should_skip_autosave

        if should_skip_autosave(history):
            return False

        autosave_dir = str(_path_autosave_dir())
        _assert_write_allowed(autosave_dir, "auto_save_session")
        os.makedirs(autosave_dir, mode=0o700, exist_ok=True)

        session_name = runtime_state.get_current_autosave_session_name()

        from code_puppy.session_storage import save_session_async

        save_session_async(session_name, history)

        emit_info(f"💾 Session auto-saved as {session_name}")
        return True
    except Exception:
        return False


def finalize_autosave_session() -> str:
    """Persist the current autosave snapshot and rotate to a fresh session."""
    from code_puppy import runtime_state

    return runtime_state.finalize_autosave_session()
