"""Agent configuration accessors.

Mirrors ``CodePuppyControl.Config.Agents`` in the Elixir runtime.

Manages the default agent, agent directories, and personalization settings.

Config keys in puppy.cfg:

- ``default_agent`` — name of the default agent (default ``"code-puppy"``)
- ``puppy_name`` — display name for the puppy
- ``owner_name`` — display name for the owner
"""

from __future__ import annotations

import os

from code_puppy.config.loader import (
    _registered_cache,
    get_value,
    set_config_value,
)
from code_puppy.config.paths import (
    _path_agents_dir,
)

__all__ = [
    "get_default_agent",
    "set_default_agent",
    "get_puppy_name",
    "get_owner_name",
    "get_user_agents_directory",
    "get_project_agents_directory",
    "get_puppy_token",
    "set_puppy_token",
]


# ---------------------------------------------------------------------------
# Default agent
# ---------------------------------------------------------------------------


def get_default_agent() -> str:
    """Return the default agent name. Falls back to ``"code-puppy"``."""
    return get_value("default_agent") or "code-puppy"


def set_default_agent(agent_name: str) -> None:
    """Set the default agent name in puppy.cfg."""
    set_config_value("default_agent", agent_name)


# ---------------------------------------------------------------------------
# Personalization
# ---------------------------------------------------------------------------


def get_puppy_name() -> str:
    """Return the puppy's display name. Defaults to ``"Puppy"``."""
    return get_value("puppy_name") or "Puppy"


def get_owner_name() -> str:
    """Return the owner's display name. Defaults to ``"Master"``."""
    return get_value("owner_name") or "Master"


# ---------------------------------------------------------------------------
# Puppy token
# ---------------------------------------------------------------------------


@_registered_cache
def get_puppy_token() -> str | None:
    """Returns the puppy_token from config, or None if not set."""
    return get_value("puppy_token")


def set_puppy_token(token: str) -> None:
    """Sets the puppy_token in the persistent config file."""
    set_config_value("puppy_token", token)


# ---------------------------------------------------------------------------
# Agent directories
# ---------------------------------------------------------------------------


def get_user_agents_directory() -> str:
    """Return the user-level agents directory. Ensures it exists.

    ADR-003: Resolves via _path_agents_dir which respects pup-ex isolation.
    """
    agents_dir = str(_path_agents_dir())
    if not os.path.exists(agents_dir):
        from code_puppy.config_paths import safe_mkdir_p

        safe_mkdir_p(agents_dir)
    return agents_dir


def get_project_agents_directory() -> str | None:
    """Return the project-local agents directory if it exists, or None.

    Project-local agents are NOT subject to the isolation guard (they
    live in ``.code_puppy/agents/`` in the CWD).
    """
    path = os.path.join(os.getcwd(), ".code_puppy", "agents")
    if os.path.isdir(path):
        return path
    return None
