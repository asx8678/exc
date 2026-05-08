"""Plugin-level config helpers for agent_skills."""

import json
import logging
from pathlib import Path

from code_puppy.config import get_value, set_value
from code_puppy.config_paths import resolve_path

logger = logging.getLogger(__name__)


def get_skill_directories() -> list[str]:
    """Get configured skill directories.

    Returns:
        List of skill directory paths from configuration.
        Reads from puppy.cfg [puppy] section under 'skill_directories' key.
        Default: ['~/.code_puppy/skills', './.code_puppy/skills', './skills']

    The directories are stored as a JSON list in the config.
    """
    # Try to read from config first
    config_value = get_value("skill_directories")

    if config_value:
        try:
            # Parse as JSON
            directories = json.loads(config_value)
            # Ensure it's a list
            if isinstance(directories, list):
                return directories
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse skill_directories config: {e}")

    # Fallback to defaults
    home_skills = str(resolve_path("skills"))
    project_config_skills = str(Path.cwd() / ".code_puppy" / "skills")
    local_skills = str(Path.cwd() / "skills")
    return [
        home_skills,
        project_config_skills,
        local_skills,
    ]


def add_skill_directory(path: str) -> bool:
    """Add a directory to the skills search path.

    Args:
        path: Path to add to the skill directories list.

    Returns:
        True if the directory was added successfully, False otherwise.
    """
    directories = get_skill_directories()

    # Check if already exists
    if path in directories:
        logger.info(f"Skill directory already exists: {path}")
        return False

    # Add the new directory
    directories.append(path)

    try:
        # Save back to config as JSON
        set_value("skill_directories", json.dumps(directories))
        logger.info(f"Added skill directory: {path}")
        return True
    except Exception as e:
        logger.error(f"Failed to add skill directory: {e}")
        return False


def remove_skill_directory(path: str) -> bool:
    """Remove a directory from the skills search path.

    Args:
        path: Path to remove from the skill directories list.

    Returns:
        True if the directory was removed successfully, False otherwise.
    """
    directories = get_skill_directories()

    # Check if exists
    if path not in directories:
        logger.info(f"Skill directory not found: {path}")
        return False

    # Remove the directory
    directories.remove(path)

    try:
        # Save back to config as JSON
        set_value("skill_directories", json.dumps(directories))
        logger.info(f"Removed skill directory: {path}")
        return True
    except Exception as e:
        logger.error(f"Failed to remove skill directory: {e}")
        return False


def get_skills_enabled() -> bool:
    """Check if skills integration is globally enabled.

    Returns:
        True if skills are globally enabled, False otherwise.
        Reads from 'skills_enabled' config key (default: True).
    """
    cfg_val = get_value("skills_enabled")
    if cfg_val is None:
        return True  # Enabled by default
    return str(cfg_val).strip().lower() in {"1", "true", "yes", "on"}


def set_skills_enabled(enabled: bool) -> None:
    """Enable or disable skills integration globally.

    Args:
        enabled: True to enable, False to disable.
    """
    set_value("skills_enabled", "true" if enabled else "false")
    logger.info(f"Skills integration {'enabled' if enabled else 'disabled'}")


def get_disabled_skills() -> set[str]:
    """Get set of explicitly disabled skill names.

    Returns:
        Set of skill names that are disabled.
        Reads from 'disabled_skills' config key as a JSON list.
    """
    config_value = get_value("disabled_skills")

    if config_value:
        try:
            # Parse as JSON
            disabled_list = json.loads(config_value)
            # Ensure it's a list and convert to set
            if isinstance(disabled_list, list):
                return set(disabled_list)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse disabled_skills config: {e}")

    return set()


def set_skill_disabled(skill_name: str, disabled: bool) -> None:
    """Disable or re-enable a specific skill.

    Args:
        skill_name: Name of the skill to disable/enable.
        disabled: True to disable, False to enable.
    """
    disabled_skills = get_disabled_skills()

    if disabled:
        # Add to disabled set
        if skill_name in disabled_skills:
            logger.info(f"Skill already disabled: {skill_name}")
            return
        disabled_skills.add(skill_name)
        logger.info(f"Disabled skill: {skill_name}")
    else:
        # Remove from disabled set
        if skill_name not in disabled_skills:
            logger.info(f"Skill already enabled: {skill_name}")
            return
        disabled_skills.remove(skill_name)
        logger.info(f"Enabled skill: {skill_name}")

    # Save back to config as JSON
    set_value("disabled_skills", json.dumps(list(disabled_skills)))


def get_progressive_skill_disclosure() -> bool:
    """Check if progressive skill disclosure is enabled.

    Progressive disclosure injects only metadata (name, description, path)
    into system prompts, allowing agents to pull full SKILL.md content
    on-demand using the read_file tool. This prevents context explosion
    when many skills are installed.

    Returns:
        True if progressive disclosure is enabled (default), False otherwise.
        Reads from 'progressive_skill_disclosure' config key.
    """
    cfg_val = get_value("progressive_skill_disclosure")
    if cfg_val is None:
        return True  # Enabled by default
    return str(cfg_val).strip().lower() in {"1", "true", "yes", "on"}


def set_progressive_skill_disclosure(enabled: bool) -> None:
    """Enable or disable progressive skill disclosure.

    Args:
        enabled: True to enable (metadata-only injection), False to disable
                 (legacy full-content injection).
    """
    set_value("progressive_skill_disclosure", "true" if enabled else "false")
    logger.info(f"Progressive skill disclosure {'enabled' if enabled else 'disabled'}")
