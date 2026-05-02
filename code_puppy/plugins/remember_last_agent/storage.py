"""Storage module for persisting the last selected agent.

Stores the last agent name in a JSON file in the state directory.
"""

import json
from pathlib import Path
from typing import Any

from code_puppy.config import STATE_DIR

# File to store the last selected agent
_LAST_AGENT_FILE = Path(STATE_DIR) / "last_agent.json"


def _ensure_state_dir() -> None:
    """Ensure the state directory exists."""
    _LAST_AGENT_FILE.parent.mkdir(parents=True, exist_ok=True)


def get_last_agent() -> str | None:
    """Get the last selected agent name.

    Returns:
        The agent name if one was saved, None otherwise.
    """
    try:
        if not _LAST_AGENT_FILE.exists():
            return None
        with open(_LAST_AGENT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("agent_name")
    except json.JSONDecodeError, IOError, OSError, KeyError:
        # File corrupted or permission issues
        return None


def set_last_agent(agent_name: str) -> None:
    """Save the last selected agent name.

    Args:
        agent_name: The name of the agent to save.
    """
    try:
        _ensure_state_dir()
        data: dict[str, Any] = {"agent_name": agent_name}

        # Write atomically (write to temp file, then rename)
        temp_file = _LAST_AGENT_FILE.with_suffix(".tmp")
        from code_puppy.config_paths import assert_write_allowed

        assert_write_allowed(temp_file, "save_last_agent")
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        temp_file.replace(_LAST_AGENT_FILE)
    except IOError, OSError:
        # File permission issues - just continue without persistence
        pass


def clear_last_agent() -> None:
    """Clear the saved last agent."""
    try:
        if _LAST_AGENT_FILE.exists():
            _LAST_AGENT_FILE.unlink()
    except IOError, OSError:
        pass
