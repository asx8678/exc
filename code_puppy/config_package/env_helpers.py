"""Typed environment variable helpers with multi-name fallback support.

This module provides a clean, consistent way to read environment variables
with type coercion and multi-name fallback support. It's particularly useful
for supporting legacy environment variable names alongside new ones during
configuration transitions.

Pattern Overview:
- All functions accept variadic name arguments (*names: str)
- Names are checked in order, first non-empty value wins
- Parsing failures fall back to the default value (never raise)
- All paths are expanded (~) and resolved

When to Use:
- Reading configuration from environment variables
- Supporting backward-compatible legacy names
- Ensuring consistent type coercion across the codebase

Examples:
    >>> # Multi-name fallback for backward compatibility
    >>> data_dir = env_path("PUPPY_DATA_DIR", "CODE_PUPPY_DATA_DIR", default="~/.code_puppy")

    >>> # Boolean feature flag with legacy name support
    >>> debug_mode = env_bool("DEBUG", "PUPPY_DEBUG", "CODE_PUPPY_DEBUG", default=False)

    >>> # Integer with fallback chain
    >>> max_workers = env_int("MAX_WORKERS", "PUPPY_MAX_WORKERS", default=4)
"""

import os
from pathlib import Path

__all__ = ["get_first_env", "env_bool", "env_int", "env_path"]


def get_first_env(*names: str) -> str | None:
    """Return the first non-empty environment variable among names.

    Useful for supporting legacy names alongside new ones:
        >>> get_first_env("PUPPY_DATA_DIR", "CODE_PUPPY_DATA_DIR")

    Args:
        *names: One or more environment variable names to check.

    Returns:
        The first non-empty string value found, or None if all are empty/unset.

    Examples:
        >>> # First var set wins
        >>> get_first_env("NEW_VAR", "LEGACY_VAR")

        >>> # Empty values are skipped (not considered set)
        >>> get_first_env("EMPTY_VAR", "ACTUAL_VAR")  # EMPTY_VAR="" → skips to ACTUAL_VAR

        >>> # Single name is fine too
        >>> get_first_env("SINGLE_VAR")
    """
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def env_bool(*names: str, default: bool) -> bool:
    """Parse a bool-like env var with multi-name fallback.

    Accepts: "1", "true", "yes", "on" (case-insensitive) as True.
    Anything else (including empty) falls through to default.

    Args:
        *names: One or more environment variable names to check.
        default: The boolean value to return if no valid env var is found.

    Returns:
        True if any env var is truthy-like, False if explicitly falsy-like,
        otherwise the default value.

    Examples:
        >>> # All of these return True (case-insensitive)
        >>> env_bool("DEBUG", default=False)  # DEBUG="1"
        >>> env_bool("DEBUG", default=False)  # DEBUG="true"
        >>> env_bool("DEBUG", default=False)  # DEBUG="yes"
        >>> env_bool("DEBUG", default=False)  # DEBUG="TRUE"

        >>> # These fall back to default (not considered "truthy")
        >>> env_bool("DEBUG", default=False)  # DEBUG="0" → False (the default)
        >>> env_bool("DEBUG", default=False)  # DEBUG="false" → False
        >>> env_bool("DEBUG", default=False)  # DEBUG="" → False
        >>> env_bool("DEBUG", default=False)  # DEBUG="maybe" → False
    """
    raw = get_first_env(*names)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def env_int(*names: str, default: int) -> int:
    """Parse an int env var with multi-name fallback. Falls back to default on ValueError.

    Args:
        *names: One or more environment variable names to check.
        default: The integer value to return if no valid env var is found.

    Returns:
        The parsed integer value, or default if parsing fails or no var is set.

    Examples:
        >>> env_int("MAX_WORKERS", default=4)  # MAX_WORKERS="8" → 8
        >>> env_int("MAX_WORKERS", default=4)  # MAX_WORKERS="invalid" → 4
        >>> env_int("MAX_WORKERS", default=4)  # (unset) → 4

        >>> # Legacy name fallback
        >>> env_int("NEW_TIMEOUT", "OLD_TIMEOUT", default=30)
    """
    raw = get_first_env(*names)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def env_path(*names: str, default: str | Path) -> Path:
    """Return a resolved Path from env var (with ~ expansion), else default resolved.

    Args:
        *names: One or more environment variable names to check.
        default: The default path to use if no env var is set. Can be str or Path.

    Returns:
        A fully resolved Path object with ~ expanded to the user's home directory.

    Examples:
        >>> env_path("DATA_DIR", default="~/.code_puppy")

        >>> # Legacy name support
        >>> env_path("PUPPY_CONFIG", "CODE_PUPPY_CONFIG", default="~/.config/puppy")

        >>> # Works with Path defaults too
        >>> env_path("CACHE_DIR", default=Path("/tmp/cache"))
    """
    raw = get_first_env(*names)
    if raw is None:
        path_value = default
    else:
        path_value = raw

    # Convert to Path if string, then expand ~ and resolve
    path = Path(path_value)
    return path.expanduser().resolve()
