"""Dual-home config isolation plugin for code_puppy.

Per ADR-003, this plugin enforces that when running as pup-ex (Elixir
runtime), all file writes go to ``~/.code_puppy_ex/`` (or ``PUP_EX_HOME``)
and NEVER to ``~/.code_puppy/``.

Hooks used:
- ``file_permission``: Blocks writes to the legacy home when in pup-ex mode.
- ``startup``: Logs the active home directory on boot.
- ``load_prompt``: Adds isolation-aware path information to agent prompts.
"""

import logging
import os

from code_puppy.callbacks import register_callback
from code_puppy.config_paths import _canonical, home_dir, is_pup_ex, legacy_home_dir

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Startup hook — log active home
# ---------------------------------------------------------------------------


def _on_startup() -> None:
    """Log which home directory is active at startup."""
    active_home = home_dir()
    if is_pup_ex():
        logger.info(
            "dual_home: pup-ex mode active, home=%s (legacy=%s is read-only)",
            active_home,
            legacy_home_dir(),
        )
    else:
        logger.debug("dual_home: standard pup mode, home=%s", active_home)


# ---------------------------------------------------------------------------
# file_permission hook — block mutating ops to legacy home in pup-ex mode
# ---------------------------------------------------------------------------

_READONLY_OPERATION_PREFIXES = ("read", "view", "list", "stat", "inspect")


def _is_legacy_target(file_path: str) -> bool:
    canonical_path = _canonical(file_path)
    canonical_legacy = _canonical(legacy_home_dir())
    return canonical_path == canonical_legacy or canonical_path.startswith(
        canonical_legacy + os.sep
    )


def _is_mutating_operation(operation: str) -> bool:
    normalized = (operation or "").strip().lower()
    if not normalized:
        return True
    return not normalized.startswith(_READONLY_OPERATION_PREFIXES)


def _on_file_permission(
    context: dict,
    file_path: str,
    operation: str,
    **kwargs,
) -> bool:
    """Check whether a file operation is allowed under isolation rules.

    Returns:
        True if the operation is allowed, False if it should be blocked.

    When running as pup-ex, legacy-home targets are read-only. Any operation
    that is not explicitly recognized as read-only is denied to fail closed
    against new mutating operation labels.
    """
    if not is_pup_ex():
        return True

    if _is_legacy_target(file_path) and _is_mutating_operation(operation):
        logger.warning(
            "dual_home: blocked %s to legacy path %s in pup-ex mode",
            operation,
            _canonical(file_path),
        )
        return False

    return True


# ---------------------------------------------------------------------------
# load_prompt hook — add isolation info to agent prompt
# ---------------------------------------------------------------------------


def _on_load_prompt() -> str | None:
    """Add dual-home isolation context to the agent prompt."""
    if is_pup_ex():
        active = home_dir()
        legacy = legacy_home_dir()
        return (
            f"\n\n## Dual-Home Isolation (pup-ex mode)\n"
            f"- Active home: {active}\n"
            f"- Legacy home ({legacy}) is READ-ONLY.\n"
            f"- NEVER write to {legacy}. All writes must go to {active}.\n"
            f"- Use `from code_puppy.config_paths import safe_write` for guarded writes.\n"
        )
    return None


# ---------------------------------------------------------------------------
# Register all hooks
# ---------------------------------------------------------------------------

register_callback("startup", _on_startup)
register_callback("file_permission", _on_file_permission)
register_callback("load_prompt", _on_load_prompt)
