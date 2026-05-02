"""Core config loader: INI parser, ConfigState, cache invalidation, getter factories.

This is the foundational module for all config access. It provides:

* ``ConfigState`` — encapsulates mutable module-level state
* ``_get_config()`` / ``_invalidate_config()`` — cached INI file reads
* ``_registered_cache`` — decorator for auto-invalidated cached getters
* ``_is_truthy`` / ``_make_bool_getter`` / ``_make_int_getter`` / ``_make_float_getter``
* ``get_value`` / ``set_value`` / ``set_config_value`` / ``reset_value``
* ``get_config_keys`` / ``get_default_config_keys``
* ``ensure_config_exists``

ADR-003: All write paths call ``_assert_write_allowed`` from config_paths.
"""

from __future__ import annotations

import configparser
import os
import pathlib
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from functools import cache
from io import StringIO
from pathlib import Path
from typing import TYPE_CHECKING

from code_puppy.config_paths import (
    assert_write_allowed as _assert_write_allowed,
)
from code_puppy.config_paths import (
    home_dir as _home_dir,
)
from code_puppy.config_paths import (
    is_pup_ex,
)
from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache

if TYPE_CHECKING:
    pass

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_SECTION = "puppy"
REQUIRED_KEYS = ["puppy_name", "owner_name"]

# Compiled regex for _sanitize_model_name_for_key
_SANITIZE_MODEL_NAME_RE = re.compile(r"[.\-/]")

# Truthy string values recognized by _is_truthy()
_TRUTHY_VALUES = frozenset({"1", "true", "yes", "on"})

# ---------------------------------------------------------------------------
# XDG path helpers (uncached — always reads current env vars)
# ---------------------------------------------------------------------------


def _get_xdg_dir_cached(env_var: str, fallback: str) -> str:
    """Get directory for code_puppy files (lru_cached — deprecated).

    Use :func:`_get_xdg_dir` instead. Retained for backward compat.
    """
    return _get_xdg_dir(env_var, fallback)


@thread_safe_lru_cache(maxsize=4)
def _get_xdg_dir(env_var: str, fallback: str) -> str:
    """Get XDG directory (uncached: always reads current env var).

    ADR-003: In pup-ex mode, XDG-derived paths MUST remain under
    the active home tree. If the XDG env var points outside, we ignore
    it and fall back to the active home.
    """
    xdg_base = os.getenv(env_var)
    if xdg_base:
        candidate = os.path.join(xdg_base, "code_puppy")
        # ADR-003: In pup-ex mode, XDG paths must be under active home
        from code_puppy.config_paths import _is_path_within_home

        if is_pup_ex() and not _is_path_within_home(candidate):
            return str(_home_dir())
        return candidate
    return str(_home_dir())


# ---------------------------------------------------------------------------
# ConfigState
# ---------------------------------------------------------------------------


@dataclass
class ConfigState:
    """Encapsulates all mutable module-level state for config.

    Replaces process-global variables that previously scattered
    mutable state across the module.
    """

    # Config caching (eliminates repeated disk reads)
    config_cache: configparser.ConfigParser | None = None
    config_mtime: float = 0.0
    config_path: str | None = None

    # mtime check debouncing (reduces stat syscall cost)
    last_mtime_check: float = 0.0
    cached_mtime: float | None = None

    # Thread-safe lock for config cache access
    config_lock: threading.Lock = field(default_factory=threading.Lock)

    # Model validation and defaults caching
    model_validation_cache: dict = field(default_factory=dict)
    default_model_cache: str | None = None
    default_vision_model_cache: str | None = None
    supported_settings_cache: Callable | None = None

    # Model context length cache
    model_context_length_cache: dict[str, int] = field(default_factory=dict)

    # Model settings cache: O(1) lookup per model (fixes CFG-H1)
    model_settings_cache: dict[str, dict] = field(default_factory=dict)


# Module-level singleton
_state = ConfigState()


def get_config_state() -> ConfigState:
    """Return the singleton ConfigState (for cross-module access)."""
    return _state


# ---------------------------------------------------------------------------
# Registry of cached getter functions for automatic invalidation
# ---------------------------------------------------------------------------

_CACHED_GETTERS: list[Callable[[], None]] = []


def _registered_cache(func: Callable) -> Callable:
    """Decorator to register a cached function for auto-invalidation.

    The cache key incorporates the effective config path so callers that
    monkeypatch CONFIG_FILE get fresh values automatically.
    """

    @cache
    def _cached(config_path: str, args: tuple, kwargs_key: tuple):
        return func(*args, **dict(kwargs_key))

    def wrapper(*args, **kwargs):
        kwargs_key = tuple(sorted(kwargs.items()))
        return _cached(str(_path_config_file()), args, kwargs_key)

    wrapper.__name__ = func.__name__
    wrapper.__doc__ = func.__doc__
    wrapper.cache_clear = _cached.cache_clear  # type: ignore[attr-defined]
    _CACHED_GETTERS.append(wrapper.cache_clear)
    return wrapper


# ---------------------------------------------------------------------------
# Core config read / write
# ---------------------------------------------------------------------------


def _get_config() -> configparser.ConfigParser:
    """Return a cached ConfigParser, re-reading only when the file changes."""
    config_path = str(_path_config_file())
    now = time.time()

    with _state.config_lock:
        if _state.config_path != config_path:
            _state.config_path = config_path
            _state.config_cache = None
            _state.config_mtime = 0.0
            _state.last_mtime_check = 0.0
            _state.cached_mtime = None

    # Only re-check mtime after TTL expires (1 second debounce)
    if now - _state.last_mtime_check > 1.0:
        try:
            _state.cached_mtime = os.path.getmtime(config_path)
        except OSError:
            cfg = configparser.ConfigParser()
            cfg.read(config_path)
            return cfg
        _state.last_mtime_check = now

    with _state.config_lock:
        if _state.config_cache is None or _state.cached_mtime != _state.config_mtime:
            _state.config_cache = configparser.ConfigParser()
            _state.config_cache.read(config_path)
            _state.config_mtime = _state.cached_mtime
        return _state.config_cache


def _invalidate_config() -> None:
    """Force next _get_config() call to re-read from disk."""
    with _state.config_lock:
        _state.config_cache = None
        _state.config_path = None
        _state.last_mtime_check = 0.0
        _state.cached_mtime = None
    # Also invalidate the protected token count cache
    from code_puppy.config.limits import get_protected_token_count

    get_protected_token_count.cache_clear()
    # Clear model caches
    _state.model_context_length_cache.clear()
    _state.model_settings_cache.clear()
    # Auto-invalidate all registered cached getters (fixes CFG-M2)
    for cache_clear in _CACHED_GETTERS:
        cache_clear()


def _is_truthy(val: str | None, default: bool = False) -> bool:
    """Parse a config value as boolean. Recognizes 1/true/yes/on as True."""
    if val is None:
        return default
    return str(val).strip().lower() in _TRUTHY_VALUES


# ---------------------------------------------------------------------------
# Getter factories
# ---------------------------------------------------------------------------


def _make_bool_getter(key: str, default: bool = False, doc: str | None = None):
    """Factory for simple boolean config getter functions."""
    getter_name = f"get_{key}"

    @_registered_cache
    def getter() -> bool:
        return _is_truthy(get_value(key), default=default)

    getter.__name__ = getter_name
    getter.__doc__ = doc or f"Return True if '{key}' is enabled (default {default})."
    return getter


def _make_int_getter(
    key: str,
    default: int,
    min_val: int | None = None,
    max_val: int | None = None,
    doc: str | None = None,
):
    """Factory for simple int config getter functions."""
    getter_name = f"get_{key}"

    @_registered_cache
    def getter() -> int:
        val = get_value(key)
        try:
            result = int(val) if val is not None else default
            if min_val is not None:
                result = max(min_val, result)
            if max_val is not None:
                result = min(max_val, result)
            return result
        except ValueError, TypeError:
            return default

    getter.__name__ = getter_name
    getter.__doc__ = (
        doc or f"Return the configured value for '{key}' as int (default {default})."
    )
    return getter


def _make_float_getter(
    key: str,
    default: float,
    min_val: float | None = None,
    max_val: float | None = None,
    doc: str | None = None,
):
    """Factory for simple float config getter functions."""
    getter_name = f"get_{key}"

    @_registered_cache
    def getter() -> float:
        val = get_value(key)
        try:
            result = float(val) if val is not None else default
            if min_val is not None:
                result = max(min_val, result)
            if max_val is not None:
                result = min(max_val, result)
            return result
        except ValueError, TypeError:
            return default

    getter.__name__ = getter_name
    getter.__doc__ = (
        doc or f"Return the configured value for '{key}' as float (default {default})."
    )
    return getter


# ---------------------------------------------------------------------------
# Public API: get / set / reset
# ---------------------------------------------------------------------------


def get_value(key: str) -> str | None:
    """Return a config value from the default section, or None."""
    config = _get_config()
    return config.get(DEFAULT_SECTION, key) if DEFAULT_SECTION in config else None


def get_config_keys() -> list[str]:
    """Return all config keys currently in puppy.cfg plus preset expected keys."""
    default_keys = get_default_config_keys()
    config = _get_config()
    keys = set(config[DEFAULT_SECTION].keys()) if DEFAULT_SECTION in config else set()
    keys.update(default_keys)
    return sorted(keys)


# Module-level cache for default config keys
_DEFAULT_CONFIG_KEYS_CACHE: list[str] | None = None


def get_default_config_keys() -> list[str]:
    """Return the list of all known/preset config keys."""
    global _DEFAULT_CONFIG_KEYS_CACHE
    if _DEFAULT_CONFIG_KEYS_CACHE is not None:
        return _DEFAULT_CONFIG_KEYS_CACHE

    # Import here to avoid circular deps at module load
    from code_puppy.config.tui import DEFAULT_BANNER_COLORS

    default_keys = [
        "yolo_mode",
        "model",
        "compaction_strategy",
        "protected_token_count",
        "compaction_threshold",
        "message_limit",
        "allow_recursion",
        "openai_reasoning_effort",
        "openai_reasoning_summary",
        "openai_verbosity",
        "auto_save_session",
        "max_saved_sessions",
        "http2",
        "diff_context_lines",
        "default_agent",
        "temperature",
        "enable_dbos",
        "enable_pack_agents",
        "enable_universal_constructor",
        "enable_streaming",
        "cancel_agent_key",
        "resume_message_count",
        "enable_user_plugins",
        "allowed_user_plugins",
    ]
    default_keys.extend(
        f"banner_color_{banner_name}" for banner_name in DEFAULT_BANNER_COLORS
    )

    _DEFAULT_CONFIG_KEYS_CACHE = default_keys
    return default_keys


def set_config_value(key: str, value: str) -> None:
    """Set a config value in the persistent config file (atomic write)."""
    from code_puppy.persistence import atomic_write_text

    config = _get_config()
    if DEFAULT_SECTION not in config:
        config[DEFAULT_SECTION] = {}
    config[DEFAULT_SECTION][key] = value

    buffer = StringIO()
    config.write(buffer)
    content = buffer.getvalue()

    # ADR-003: Guard against writing to wrong home when running as pup-ex
    _assert_write_allowed(_path_config_file(), "set_config_value")
    atomic_write_text(Path(_path_config_file()), content)
    _invalidate_config()

    # Also invalidate the typed config singleton
    try:
        from code_puppy.config_package.loader import reset_puppy_config_for_tests

        reset_puppy_config_for_tests()
    except Exception:
        pass


def set_value(key: str, value: str) -> None:
    """Set a config value. Alias for set_config_value."""
    set_config_value(key, value)


def reset_value(key: str) -> None:
    """Remove a key from the config file, resetting it to default."""
    from code_puppy.persistence import atomic_write_text

    config = _get_config()
    if DEFAULT_SECTION in config and key in config[DEFAULT_SECTION]:
        del config[DEFAULT_SECTION][key]
        buffer = StringIO()
        config.write(buffer)
        content = buffer.getvalue()
        _assert_write_allowed(_path_config_file(), "reset_value")
        atomic_write_text(Path(_path_config_file()), content)
    _invalidate_config()
    try:
        from code_puppy.config_package.loader import reset_puppy_config_for_tests

        reset_puppy_config_for_tests()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# ensure_config_exists
# ---------------------------------------------------------------------------


def ensure_config_exists() -> None:
    """Ensure all XDG directories and puppy.cfg exist.

    Creates directories and prompts for required keys if missing.
    """
    from code_puppy.config.paths import (
        _path_skills_dir,
        _xdg_cache_dir,
        _xdg_config_dir,
        _xdg_data_dir,
        _xdg_state_dir,
    )

    for directory in [
        _xdg_config_dir(),
        _xdg_data_dir(),
        _xdg_cache_dir(),
        _xdg_state_dir(),
        _path_skills_dir(),
    ]:
        if not os.path.exists(directory):
            _assert_write_allowed(directory, "ensure_config_exists")
            os.makedirs(directory, mode=0o700, exist_ok=True)

    config_file = _path_config_file()
    exists = os.path.isfile(str(config_file))
    config = configparser.ConfigParser()
    if exists:
        config.read(str(config_file))
    if DEFAULT_SECTION not in config:
        config[DEFAULT_SECTION] = {}

    missing = [
        key
        for key in REQUIRED_KEYS
        if key not in config[DEFAULT_SECTION] or config[DEFAULT_SECTION][key] == ""
    ]

    if missing:
        print("🐾 Let's get your Puppy ready!")
        for key in missing:
            prompt = (
                "What should we name the puppy? "
                if key == "puppy_name"
                else "What's your name (so Code Puppy knows its owner)? "
                if key == "owner_name"
                else f"Enter {key}: "
            )
            value = input(prompt).strip()
            config[DEFAULT_SECTION][key] = value

    if not exists or missing:
        _assert_write_allowed(config_file, "ensure_config_exists")
        Path(config_file).parent.mkdir(parents=True, exist_ok=True)
        with open(str(config_file), "w", encoding="utf-8") as f:
            config.write(f)


# ---------------------------------------------------------------------------
# Path helpers (imported from paths sub-module but used here for
# _get_config / set_config_value — circular dep avoidance)
# ---------------------------------------------------------------------------


def _path_config_file() -> pathlib.Path:
    """Return the config file path (respects pup-ex isolation).

    Import deferred to avoid circular imports at module load time.
    """
    from code_puppy.config.paths import _path_config_file as _pcf

    return _pcf()
