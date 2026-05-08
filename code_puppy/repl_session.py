"""Persistent REPL session management for Code Puppy.

This module provides a stateful interactive session that:
- Persists conversation history across restarts
- Tracks project context (loaded files, working directory)
- Supports mode switching (agents, models)
- Provides fuzzy completion and command history

The REPL reuses existing command and tool infrastructure rather than
duplicating logic.
"""

import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from code_puppy import config as puppy_config
from code_puppy.config import get_current_autosave_id
from code_puppy.messaging import emit_error, emit_success

logger = logging.getLogger(__name__)


def _repl_state_dir() -> Path:
    return Path(puppy_config.CACHE_DIR) / "repl_state"


def _repl_state_file() -> Path:
    return _repl_state_dir() / "current_session.json"


def _repl_history_file() -> Path:
    return _repl_state_dir() / "repl_history.jsonl"


@dataclass
class ReplSession:
    """Persistent REPL session state.

    Tracks conversation history, project context, and configuration
    that persists across REPL restarts.
    """

    session_id: str
    created_at: float = field(default_factory=lambda: time.time())
    updated_at: float = field(default_factory=lambda: time.time())

    # Project context
    working_directory: str = field(default_factory=lambda: str(Path.cwd()))
    loaded_files: list[str] = field(default_factory=list)
    project_root: str | None = None

    # Session configuration
    current_agent: str = "default"
    current_model: str | None = None
    current_mode: str = "semi"  # basic, semi, full, pack
    current_pack: str = "single"  # model pack

    # Session metadata
    message_count: int = 0
    command_count: int = 0
    last_command: str | None = None

    # Conversation snapshot (reference to autosave)
    autosave_session_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        """Serialize session to dictionary."""
        return {
            "session_id": self.session_id,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "working_directory": self.working_directory,
            "loaded_files": self.loaded_files,
            "project_root": self.project_root,
            "current_agent": self.current_agent,
            "current_model": self.current_model,
            "current_mode": self.current_mode,
            "current_pack": self.current_pack,
            "message_count": self.message_count,
            "command_count": self.command_count,
            "last_command": self.last_command,
            "autosave_session_id": self.autosave_session_id,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ReplSession":
        """Create session from dictionary."""
        return cls(
            session_id=data.get("session_id", get_current_autosave_id()),
            created_at=data.get("created_at", time.time()),
            updated_at=data.get("updated_at", time.time()),
            working_directory=data.get("working_directory", str(Path.cwd())),
            loaded_files=data.get("loaded_files", []),
            project_root=data.get("project_root"),
            current_agent=data.get("current_agent", "default"),
            current_model=data.get("current_model"),
            current_mode=data.get("current_mode", "semi"),
            current_pack=data.get("current_pack", "single"),
            message_count=data.get("message_count", 0),
            command_count=data.get("command_count", 0),
            last_command=data.get("last_command"),
            autosave_session_id=data.get("autosave_session_id"),
        )

    def touch(self) -> None:
        """Update the last modified timestamp."""
        self.updated_at = time.time()


# Global session instance (lazy-loaded)
_current_session: ReplSession | None = None


def get_repl_state_dir() -> Path:
    """Get the REPL state directory, creating it if needed."""
    state_dir = _repl_state_dir()
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir


def get_current_session() -> ReplSession:
    """Get the current REPL session, loading from disk if needed."""
    global _current_session

    if _current_session is None:
        _current_session = load_session()

    return _current_session


def load_session() -> ReplSession:
    """Load REPL session from disk, or create a new one."""
    state_file = _repl_state_file()
    if state_file.exists():
        try:
            with open(state_file, "r") as f:
                data = json.load(f)
            session = ReplSession.from_dict(data)
            logger.debug(f"Loaded REPL session: {session.session_id}")
            return session
        except Exception as e:
            logger.warning(f"Failed to load REPL session: {e}")

    # Create new session
    session = ReplSession(session_id=get_current_autosave_id())
    logger.debug(f"Created new REPL session: {session.session_id}")
    return session


def save_session(session: ReplSession | None = None) -> None:
    """Save REPL session to disk."""
    if session is None:
        session = get_current_session()

    session.touch()
    get_repl_state_dir()

    try:
        with open(_repl_state_file(), "w") as f:
            json.dump(session.to_dict(), f, indent=2)
        logger.debug(f"Saved REPL session: {session.session_id}")
    except Exception as e:
        logger.error(f"Failed to save REPL session: {e}")


def reset_session() -> ReplSession:
    """Reset the REPL session to a fresh state."""
    global _current_session

    _current_session = ReplSession(session_id=get_current_autosave_id())
    save_session(_current_session)

    # Also reset workflow state
    try:
        from code_puppy.workflow_state import reset_workflow_state

        reset_workflow_state()
    except Exception:
        pass

    logger.debug("Reset REPL session")
    return _current_session


def update_session(**kwargs) -> None:
    """Update current session with new values and save."""
    session = get_current_session()

    for key, value in kwargs.items():
        if hasattr(session, key):
            setattr(session, key, value)
        else:
            logger.warning(f"Unknown session attribute: {key}")

    save_session(session)


def record_command(command: str) -> None:
    """Record a command in session history."""
    session = get_current_session()
    session.command_count += 1
    session.last_command = command
    session.touch()

    # Append to history file
    try:
        with open(_repl_history_file(), "a") as f:
            entry = {
                "timestamp": time.time(),
                "command": command,
                "session_id": session.session_id,
            }
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.debug(f"Failed to write command history: {e}")

    save_session(session)


def get_command_history(limit: int = 100) -> list[dict[str, Any]]:
    """Get recent command history."""
    history_file = _repl_history_file()
    if not history_file.exists():
        return []

    try:
        with open(history_file, "r") as f:
            lines = f.readlines()

        # Parse last N entries
        entries = []
        for line in lines[-limit:]:
            try:
                entry = json.loads(line.strip())
                entries.append(entry)
            except json.JSONDecodeError:
                continue

        return entries
    except Exception as e:
        logger.warning(f"Failed to read command history: {e}")
        return []


def add_loaded_file(file_path: str) -> None:
    """Track a file as being loaded into context."""
    session = get_current_session()

    # Normalize path
    try:
        path = Path(file_path).resolve()
        str_path = str(path)
    except Exception:
        str_path = file_path

    # Add if not already present
    if str_path not in session.loaded_files:
        session.loaded_files.append(str_path)
        save_session(session)


def remove_loaded_file(file_path: str) -> None:
    """Remove a file from the loaded context."""
    session = get_current_session()

    try:
        path = Path(file_path).resolve()
        str_path = str(path)
    except Exception:
        str_path = file_path

    if str_path in session.loaded_files:
        session.loaded_files.remove(str_path)
        save_session(session)


def clear_loaded_files() -> None:
    """Clear all loaded files from context."""
    session = get_current_session()
    session.loaded_files = []
    save_session(session)


def get_session_summary() -> str:
    """Get a human-readable summary of current session."""
    session = get_current_session()

    lines = [
        f"Session: {session.session_id[:8]}...",
        f"Commands: {session.command_count}",
        f"Loaded files: {len(session.loaded_files)}",
        f"Agent: {session.current_agent}",
    ]

    if session.current_model:
        lines.append(f"Model: {session.current_model}")

    lines.append(f"Mode: {session.current_mode}")
    lines.append(f"Pack: {session.current_pack}")

    return " | ".join(lines)


def switch_mode(mode: str) -> bool:
    """Switch the REPL mode (basic/semi/full/pack)."""
    from code_puppy.config_presets import apply_preset

    valid_modes = ["basic", "semi", "full", "pack"]
    if mode not in valid_modes:
        emit_error(f"Invalid mode: {mode}. Valid modes: {', '.join(valid_modes)}")
        return False

    # Apply the preset
    if apply_preset(mode, emit=True):
        update_session(current_mode=mode)
        emit_success(f"Switched to {mode} mode")
        return True

    return False


def switch_agent(agent_name: str) -> bool:
    """Switch the current agent."""
    try:
        from code_puppy.agents import set_agent_by_name

        if set_agent_by_name(agent_name):
            update_session(current_agent=agent_name)
            emit_success(f"Switched to {agent_name} agent")
            return True
        else:
            emit_error(f"Failed to switch to {agent_name} agent")
            return False
    except Exception as e:
        emit_error(f"Error switching agent: {e}")
        return False


def switch_model(model_name: str) -> bool:
    """Switch the current model."""
    try:
        from code_puppy.config import set_model_name

        set_model_name(model_name)
        update_session(current_model=model_name)
        emit_success(f"Switched to {model_name} model")
        return True
    except Exception as e:
        emit_error(f"Error switching model: {e}")
        return False


def switch_pack(pack_name: str) -> bool:
    """Switch the model pack."""
    from code_puppy.model_packs import set_current_pack

    if set_current_pack(pack_name):
        update_session(current_pack=pack_name)
        return True
    return False


def link_autosave_session(autosave_id: str) -> None:
    """Link the REPL session to an autosave session."""
    update_session(autosave_session_id=autosave_id)


def import_session_from_autosave(autosave_id: str) -> bool:
    """Import conversation history from an autosave session."""
    try:
        from code_puppy.config import AUTOSAVE_DIR
        from code_puppy.session_storage import load_session as load_autosave

        autosave_path = Path(AUTOSAVE_DIR) / f"{autosave_id}.msgpack"
        if not autosave_path.exists():
            emit_error(f"Autosave session not found: {autosave_id}")
            return False

        # Load the autosave to get message count
        messages = load_autosave(autosave_id, base_dir=Path(AUTOSAVE_DIR))

        # Update session
        update_session(
            autosave_session_id=autosave_id,
            message_count=len(messages) if messages else 0,
        )

        emit_success(
            f"Imported session with {len(messages) if messages else 0} messages"
        )
        return True

    except Exception as e:
        emit_error(f"Failed to import session: {e}")
        return False
