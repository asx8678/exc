"""
Configuration loader for Claude Code hooks.

Loads and merges hooks from multiple locations:
1. ~/.code_puppy/hooks.json (global level) - always loaded if exists
2. .claude/settings.json (project-level) - merged with global

Both configurations are loaded and merged so that hooks from both levels
coexist and execute together.
"""

import json
import logging
import os
from pathlib import Path
from typing import Any

from code_puppy.config_paths import resolve_path

logger = logging.getLogger(__name__)

PROJECT_HOOKS_FILE = ".claude/settings.json"


# Respects pup-ex isolation (ADR-003) — resolves under active home
def _global_hooks_file() -> str:
    """Return the global hooks file path under the active home.

    Honors a patched ``GLOBAL_HOOKS_FILE`` module attribute when present for
    backward-compatible tests and explicit overrides.
    """
    override = globals().get("GLOBAL_HOOKS_FILE")
    if override is not None:
        return str(override)
    return str(resolve_path("hooks.json"))


def __getattr__(name: str):
    """Lazy resolution of env-sensitive module-level names."""
    if name == "GLOBAL_HOOKS_FILE":
        return _global_hooks_file()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def _deep_merge_hooks(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """
    Merge hook configurations, combining event types and hook groups.

    When the same event type exists in both base and overlay, their hook groups
    are concatenated (overlay hooks appear after base hooks).

    Args:
        base: Base configuration dictionary
        overlay: Configuration to merge on top

    Returns:
        Merged configuration with all hooks from both sources
    """
    merged = dict(base)

    for event_type, hook_groups in overlay.items():
        if event_type.startswith("_"):
            # Skip comment keys
            merged[event_type] = hook_groups
            continue

        if event_type not in merged:
            # New event type, just add it
            merged[event_type] = hook_groups
        elif isinstance(merged[event_type], list) and isinstance(hook_groups, list):
            # Both are lists, concatenate them (overlay hooks come after)
            merged[event_type] = merged[event_type] + hook_groups
            logger.debug(
                f"Merged {len(hook_groups)} hook group(s) for event '{event_type}'"
            )
        else:
            # Type mismatch or unexpected structure, keep base
            logger.warning(
                f"Cannot merge event type '{event_type}': type mismatch or unexpected structure"
            )

    return merged


def load_hooks_config() -> dict[str, Any] | None:
    """
    Load and merge hooks configuration from available sources.

    Priority order:
    1. ~/.code_puppy/hooks.json (global level) - always loaded if exists
    2. .claude/settings.json (project-level) - merged with global

    Returns:
        Configuration dictionary or None if no config found
    """
    merged_config: dict[str, Any] = {}

    # Load global hooks first
    global_config_path = Path(_global_hooks_file())

    if global_config_path.exists():
        try:
            with open(global_config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
            if "hooks" in config and isinstance(config["hooks"], dict):
                logger.info(
                    f"Loaded hooks configuration (wrapped format) from {_global_hooks_file()}"
                )
                merged_config = _deep_merge_hooks(merged_config, config["hooks"])
            elif isinstance(config, dict):
                logger.info(f"Loaded hooks configuration from {_global_hooks_file()}")
                merged_config = _deep_merge_hooks(merged_config, config)
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in {_global_hooks_file()}: {e}")
        except Exception as e:
            logger.error(f"Failed to load {_global_hooks_file()}: {e}", exc_info=True)

    # Load and merge project-level hooks
    project_config_path = Path(os.getcwd()) / PROJECT_HOOKS_FILE

    if project_config_path.exists():
        try:
            with open(project_config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
            hooks_config = config.get("hooks")
            if hooks_config:
                logger.info(f"Merging hooks configuration from {project_config_path}")
                merged_config = _deep_merge_hooks(merged_config, hooks_config)
            else:
                logger.debug(f"No 'hooks' section found in {project_config_path}")
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in {project_config_path}: {e}")
        except Exception as e:
            logger.error(f"Failed to load {project_config_path}: {e}", exc_info=True)

    if not merged_config:
        logger.debug("No hooks configuration found")
        return None

    event_count = len(
        [event for event in merged_config.keys() if not event.startswith("_")]
    )
    logger.info(f"Hooks configuration ready ({event_count} event type(s))")
    return merged_config


def get_hooks_config_paths() -> list:
    """
    Return list of hook configuration paths.

    Returns paths in order of precedence (project-level first, then global).
    Note: internally, hooks are loaded in reverse order (global first, then project)
    so that project-level hooks can extend/append to global hooks.
    """
    return [
        str(Path(os.getcwd()) / PROJECT_HOOKS_FILE),
        _global_hooks_file(),
    ]
