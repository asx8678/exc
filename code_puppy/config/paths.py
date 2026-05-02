"""XDG-compatible path resolution for Code Puppy directories and files.

Mirrors ``CodePuppyControl.Config.Paths`` in the Elixir runtime.

ADR-003: All path resolution respects pup-ex isolation. When running as
pup-ex (``PUP_EX_HOME`` set), paths resolve under ``~/.code_puppy_ex/``
and NEVER under ``~/.code_puppy/``.

This module provides lazy path accessors for INTERNAL use (``_xdg_*()``,
``_path_*()``) and a ``__getattr__``-based ``_LAZY_PATH_FACTORIES`` dict
for backward-compatible EXTERNAL access (e.g. ``config.CONFIG_FILE``).
"""

# ruff: noqa: F822 — lazy __all__ names resolved via __getattr__ (PEP 562)

from __future__ import annotations

import os
import pathlib
from collections.abc import Callable

# Re-export the core config_paths functions for convenience
from code_puppy.config_paths import (
    ConfigIsolationViolation,
    resolve_path,
    safe_append,
    safe_atomic_write,
    safe_mkdir_p,
    safe_rm,
    safe_rm_rf,
    safe_write,
    with_sandbox,
)
from code_puppy.config_paths import (
    cache_dir as _cp_cache_dir,
)
from code_puppy.config_paths import (
    config_dir as _cp_config_dir,
)
from code_puppy.config_paths import (
    data_dir as _cp_data_dir,
)
from code_puppy.config_paths import (
    state_dir as _cp_state_dir,
)

__all__ = [
    # Path constants (lazy via __getattr__)
    "STATE_DIR",
    "CONFIG_DIR",
    "CACHE_DIR",
    "AUTOSAVE_DIR",
    "EXTRA_MODELS_FILE",
    # Re-exports from config_paths
    "ConfigIsolationViolation",
    "safe_write",
    "safe_mkdir_p",
    "safe_rm",
    "safe_rm_rf",
    "safe_atomic_write",
    "safe_append",
    "with_sandbox",
    "resolve_path",
]


# ---------------------------------------------------------------------------
# XDG dir helpers — INTERNAL use only
# ---------------------------------------------------------------------------


def _get_xdg_dir(env_var: str, fallback: str) -> str:
    """Get XDG directory respecting pup-ex isolation.

    Delegates to config_paths for the canonical implementation.
    """
    from code_puppy.config.loader import _get_xdg_dir as _loader_xdg

    return _loader_xdg(env_var, fallback)


def _xdg_config_dir() -> str:
    """Return the XDG config directory (respects pup-ex isolation)."""
    return _cp_config_dir()


def _xdg_data_dir() -> str:
    """Return the XDG data directory (respects pup-ex isolation)."""
    return _cp_data_dir()


def _xdg_cache_dir() -> str:
    """Return the XDG cache directory (respects pup-ex isolation)."""
    return _cp_cache_dir()


def _xdg_state_dir() -> str:
    """Return the XDG state directory (respects pup-ex isolation)."""
    return _cp_state_dir()


# ---------------------------------------------------------------------------
# Path accessors — INTERNAL use only
# ---------------------------------------------------------------------------


def _override_str(name: str) -> str | None:
    """Check if a module-level path constant has been overridden."""
    # This is kept for backward compat with test monkeypatching.
    # Since we no longer have module-level constants, always returns None
    # unless a test injects via _LAZY_PATH_OVERRIDES.
    return _LAZY_PATH_OVERRIDES.get(name)


def _override_path(name: str) -> pathlib.Path | None:
    """Check if a module-level path constant has been overridden (Path)."""
    val = _LAZY_PATH_OVERRIDES.get(name)
    if val is None:
        return None
    return pathlib.Path(val)


# Test override dict — tests can set keys here to override paths
_LAZY_PATH_OVERRIDES: dict[str, str] = {}


def _path_config_file() -> pathlib.Path:
    """Return the config file path (respects pup-ex isolation)."""
    override = _override_path("CONFIG_FILE")
    if override is not None:
        return override
    return pathlib.Path(_xdg_config_dir()) / "puppy.cfg"


def _path_mcp_servers_file() -> pathlib.Path:
    """Return the MCP servers file path (respects pup-ex isolation)."""
    override = _override_path("MCP_SERVERS_FILE")
    if override is not None:
        return override
    return pathlib.Path(_xdg_config_dir()) / "mcp_servers.json"


def _path_agents_dir() -> pathlib.Path:
    """Return the agents directory path (respects pup-ex isolation)."""
    override = _override_path("AGENTS_DIR")
    if override is not None:
        return override
    return pathlib.Path(_xdg_data_dir()) / "agents"


def _path_skills_dir() -> pathlib.Path:
    """Return the skills directory path (respects pup-ex isolation)."""
    override = _override_path("SKILLS_DIR")
    if override is not None:
        return override
    return pathlib.Path(_xdg_data_dir()) / "skills"


def _path_autosave_dir() -> pathlib.Path:
    """Return the autosave directory path (respects pup-ex isolation)."""
    override = _override_path("AUTOSAVE_DIR")
    if override is not None:
        return override
    return pathlib.Path(_xdg_cache_dir()) / "autosaves"


def _path_command_history_file() -> pathlib.Path:
    """Return the command history file path (respects pup-ex isolation)."""
    override = _override_path("COMMAND_HISTORY_FILE")
    if override is not None:
        return override
    return pathlib.Path(_xdg_state_dir()) / "command_history.txt"


def _path_default_sqlite_file() -> pathlib.Path:
    """Return the DBOS SQLite file path (respects pup-ex isolation)."""
    override = _override_path("_DEFAULT_SQLITE_FILE")
    if override is not None:
        return override
    return pathlib.Path(_xdg_data_dir()) / "dbos_store.sqlite"


# ---------------------------------------------------------------------------
# Lazy path factories for backward-compatible external access
# ---------------------------------------------------------------------------

_LAZY_PATH_FACTORIES: dict[str, Callable[[], object]] = {
    "CONFIG_DIR": lambda: _xdg_config_dir(),
    "DATA_DIR": lambda: _xdg_data_dir(),
    "CACHE_DIR": lambda: _xdg_cache_dir(),
    "STATE_DIR": lambda: _xdg_state_dir(),
    "CONFIG_FILE": lambda: _path_config_file(),
    "MCP_SERVERS_FILE": lambda: _path_mcp_servers_file(),
    "MODELS_FILE": lambda: pathlib.Path(_xdg_data_dir()) / "models.json",
    "EXTRA_MODELS_FILE": lambda: pathlib.Path(_xdg_data_dir()) / "extra_models.json",
    "AGENTS_DIR": lambda: _path_agents_dir(),
    "SKILLS_DIR": lambda: _path_skills_dir(),
    "CONTEXTS_DIR": lambda: pathlib.Path(_xdg_data_dir()) / "contexts",
    "_DEFAULT_SQLITE_FILE": lambda: _path_default_sqlite_file(),
    "CHATGPT_MODELS_FILE": lambda: (
        pathlib.Path(_xdg_data_dir()) / "chatgpt_models.json"
    ),
    "CLAUDE_MODELS_FILE": lambda: pathlib.Path(_xdg_data_dir()) / "claude_models.json",
    "AUTOSAVE_DIR": lambda: _path_autosave_dir(),
    "COMMAND_HISTORY_FILE": lambda: _path_command_history_file(),
    "DBOS_DATABASE_URL": lambda: os.environ.get(
        "DBOS_SYSTEM_DATABASE_URL",
        f"sqlite:///{_path_default_sqlite_file()}",
    ),
}


def __getattr__(name: str):
    """Lazy path resolution for external attribute access (PEP 562).

    External code doing ``from code_puppy.config import CONFIG_FILE``
    or ``config.CONFIG_FILE`` will hit this and get a freshly-computed
    value that respects pup-ex isolation.
    """
    if name in _LAZY_PATH_FACTORIES:
        return _LAZY_PATH_FACTORIES[name]()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# Clean up any pre-existing module-level names
for _lazy_name in _LAZY_PATH_FACTORIES:
    pass  # No-op; names are resolved via __getattr__
