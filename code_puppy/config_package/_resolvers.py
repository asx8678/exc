"""Pure config resolution functions.

This module provides pure, testable helper functions for resolving
configuration values from environment variables, legacy config, and
defaults. Extracted from loader.py to improve testability and separation
of concerns.

All functions follow the same pattern:
1. Check environment variables first (highest priority)
2. Fall back to legacy config if available
3. Use hardcoded default as last resort
"""

from collections.abc import Callable
from pathlib import Path
from typing import Any

from code_puppy.config_package.env_helpers import get_first_env


def resolve_str(
    env_names: tuple[str, ...],
    legacy_key: str,
    hardcoded_default: str,
    legacy_fallback_names: tuple[str, ...] = (),
    *,
    _legacy_ok: bool,
    _legacy_config: Any,
    _get_legacy_value: Callable[[Any, str], str | None],
) -> str:
    """Get string value from env, legacy config, or default.

    Args:
        env_names: Tuple of environment variable names to check (in order).
        legacy_key: Primary key to look up in legacy config.
        hardcoded_default: Default value if no source has the value.
        legacy_fallback_names: Additional legacy keys to try if primary fails.
        _legacy_ok: Whether legacy config is available.
        _legacy_config: The legacy config module/object.
        _get_legacy_value: Function to get a value from legacy config.

    Returns:
        The resolved string value.
    """
    # Try env vars first
    env_val = get_first_env(*env_names)
    if env_val is not None:
        return env_val

    # Try legacy config if available
    if _legacy_ok:
        # First try the primary legacy key
        legacy_val = _get_legacy_value(_legacy_config, legacy_key)
        if legacy_val:
            return legacy_val

        # Try legacy fallback names (for compatibility)
        for fallback_key in legacy_fallback_names:
            legacy_val = _get_legacy_value(_legacy_config, fallback_key)
            if legacy_val:
                return legacy_val

    return hardcoded_default


def resolve_bool(
    env_names: tuple[str, ...],
    legacy_key: str,
    hardcoded_default: bool,
    *,
    _legacy_ok: bool,
    _legacy_config: Any,
    _get_legacy_value: Callable[[Any, str], str | None],
) -> bool:
    """Get boolean value from env, legacy config, or default.

    Args:
        env_names: Tuple of environment variable names to check.
        legacy_key: Key to look up in legacy config.
        hardcoded_default: Default value if no source has the value.
        _legacy_ok: Whether legacy config is available.
        _legacy_config: The legacy config module/object.
        _get_legacy_value: Function to get a value from legacy config.

    Returns:
        The resolved boolean value. Truthy strings: 1, true, yes, on.
    """
    # Check env vars first
    raw_env = get_first_env(*env_names)
    if raw_env is not None:
        return raw_env.strip().lower() in {"1", "true", "yes", "on"}

    # Try legacy config
    if _legacy_ok:
        legacy_val = _get_legacy_value(_legacy_config, legacy_key)
        if legacy_val is not None:
            return legacy_val.strip().lower() in {"1", "true", "yes", "on"}

    return hardcoded_default


def resolve_int(
    env_names: tuple[str, ...],
    legacy_key: str,
    hardcoded_default: int,
    min_val: int | None = None,
    max_val: int | None = None,
    *,
    _legacy_ok: bool,
    _legacy_config: Any,
    _get_legacy_value: Callable[[Any, str], str | None],
) -> int:
    """Get integer value from env, legacy config, or default.

    Args:
        env_names: Tuple of environment variable names to check.
        legacy_key: Key to look up in legacy config.
        hardcoded_default: Default value if no source has the value.
        min_val: Optional minimum value to clamp to.
        max_val: Optional maximum value to clamp to.
        _legacy_ok: Whether legacy config is available.
        _legacy_config: The legacy config module/object.
        _get_legacy_value: Function to get a value from legacy config.

    Returns:
        The resolved integer value, optionally clamped to bounds.
    """
    # Check env vars first
    raw_env = get_first_env(*env_names)
    if raw_env is not None:
        try:
            result = int(raw_env)
            if min_val is not None:
                result = max(min_val, result)
            if max_val is not None:
                result = min(max_val, result)
            return result
        except ValueError, TypeError:
            pass

    # Try legacy config
    if _legacy_ok:
        legacy_val = _get_legacy_value(_legacy_config, legacy_key)
        if legacy_val is not None:
            try:
                result = int(legacy_val)
                if min_val is not None:
                    result = max(min_val, result)
                if max_val is not None:
                    result = min(max_val, result)
                return result
            except ValueError, TypeError:
                pass

    return hardcoded_default


def resolve_float(
    env_names: tuple[str, ...],
    legacy_key: str,
    hardcoded_default: float,
    min_val: float | None = None,
    max_val: float | None = None,
    *,
    _legacy_ok: bool,
    _legacy_config: Any,
    _get_legacy_value: Callable[[Any, str], str | None],
) -> float:
    """Get float value from env, legacy config, or default.

    Args:
        env_names: Tuple of environment variable names to check.
        legacy_key: Key to look up in legacy config.
        hardcoded_default: Default value if no source has the value.
        min_val: Optional minimum value to clamp to.
        max_val: Optional maximum value to clamp to.
        _legacy_ok: Whether legacy config is available.
        _legacy_config: The legacy config module/object.
        _get_legacy_value: Function to get a value from legacy config.

    Returns:
        The resolved float value, optionally clamped to bounds.
    """
    # Check env vars first
    raw_env = get_first_env(*env_names)
    if raw_env is not None:
        try:
            result = float(raw_env)
            if min_val is not None:
                result = max(min_val, result)
            if max_val is not None:
                result = min(max_val, result)
            return result
        except ValueError, TypeError:
            pass

    # Try legacy config
    if _legacy_ok:
        legacy_val = _get_legacy_value(_legacy_config, legacy_key)
        if legacy_val is not None:
            try:
                result = float(legacy_val)
                if min_val is not None:
                    result = max(min_val, result)
                if max_val is not None:
                    result = min(max_val, result)
                return result
            except ValueError, TypeError:
                pass

    return hardcoded_default


def resolve_path(
    env_names: tuple[str, ...],
    hardcoded_default: str | Path,
) -> Path:
    """Get path value from env or default.

    Args:
        env_names: Tuple of environment variable names to check.
        hardcoded_default: Default path to use if no env var is set.

    Returns:
        A fully resolved Path with ~ expanded.
    """
    from code_puppy.config_package.env_helpers import env_path

    return env_path(*env_names, default=hardcoded_default)
