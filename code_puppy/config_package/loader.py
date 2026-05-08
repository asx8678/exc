"""Configuration loader for code_puppy typed settings.

This module provides the loading logic for `PuppyConfig`, reading from
multiple sources in priority order:

1. Environment variables (highest priority)
2. puppy.cfg file (via legacy config module)
3. Built-in defaults (lowest priority)

Examples:
    >>> # Load fresh config (not cached)
    >>> from code_puppy.config_package.loader import load_puppy_config
    >>> cfg = load_puppy_config()

    >>> # Use singleton cache
    >>> from code_puppy.config_package import get_puppy_config
    >>> cfg = get_puppy_config() # Same instance on subsequent calls

    >>> # Reload after config changes
    >>> cfg = reload_puppy_config()
"""

import threading
from pathlib import Path
from typing import Any

from code_puppy.config_package._resolvers import (
    resolve_bool,
    resolve_float,
    resolve_int,
    resolve_str,
)
from code_puppy.config_package.env_helpers import (
    env_path,
    get_first_env,
)
from code_puppy.config_package.models import PuppyConfig
from code_puppy.constants import SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT


def _default_home() -> str:
    """Get default home directory, respecting pup-ex isolation.

    Returns the string form (with ~ expansion) of the active home dir
    so it can be used as a default for env_path() calls.
    Falls back to "~/.code_puppy" if config_paths is unavailable.
    """
    try:
        from code_puppy.config_paths import home_dir

        return str(home_dir())
    except ImportError:
        return "~/.code_puppy"


# Singleton cache
_cached_config: PuppyConfig | None = None
_cache_lock = threading.Lock()


def _env_optional_float(*names: str, default: float | None) -> float | None:
    """Parse an optional float env var. Returns default if unset or invalid.

    Args:
        *names: One or more environment variable names to check.
        default: The default value to return if no valid env var is found.

    Returns:
        The parsed float value, or default if parsing fails or no var is set.
    """
    raw = get_first_env(*names)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _get_legacy_config() -> tuple[bool, Any]:
    """Safely import and return the legacy config module.

    Returns:
        Tuple of (success: bool, config_module: Any).
        If import fails, returns (False, None).
    """
    try:
        from code_puppy import config as legacy_config

        return True, legacy_config
    except Exception:
        return False, None


def _get_legacy_value(
    legacy_config: Any, key: str, default: str | None = None
) -> str | None:
    """Safely get a value from legacy config.

    Args:
        legacy_config: The legacy config module.
        key: Config key to look up.
        default: Default value if lookup fails.

    Returns:
        The config value or default.
    """
    try:
        if hasattr(legacy_config, "get_value"):
            return legacy_config.get_value(key) or default
    except Exception:
        pass
    return default


def load_puppy_config() -> PuppyConfig:
    """Load the typed PuppyConfig from env vars, puppy.cfg, and defaults.

    Priority order (highest first):
        1. Environment variables (via env_helpers)
        2. puppy.cfg file (via legacy config module)
        3. Hardcoded defaults (lowest priority)

    This function is additive — does NOT replace code_puppy.config.
    Both APIs coexist. Use whichever fits your call site better.

    Returns:
        A fully populated PuppyConfig instance.

    Raises:
        Never raises — all failures fall back to hardcoded defaults.
        Config loading must never crash the app.

    Example:
        >>> cfg = load_puppy_config()
        >>> print(f"Using model: {cfg.default_model}")
        >>> print(f"Data dir: {cfg.data_dir}")
    """
    # Attempt to import legacy config (graceful fallback if it fails)
    legacy_ok, legacy_config = _get_legacy_config()

    # Create resolver context
    resolver_ctx = {
        "_legacy_ok": legacy_ok,
        "_legacy_config": legacy_config,
        "_get_legacy_value": _get_legacy_value,
    }

    # ─────────────────────────────────────────────────────────────
    # Build paths (using legacy constants or env vars)
    # ─────────────────────────────────────────────────────────────

    # Get base paths from legacy config or env vars
    data_dir: Path
    config_dir: Path

    if legacy_ok:
        # Use legacy constants if available
        try:
            data_dir = env_path(
                "PUPPY_DATA_DIR", "CODE_PUPPY_DATA_DIR", default=legacy_config.DATA_DIR
            )
        except Exception:
            data_dir = env_path(
                "PUPPY_DATA_DIR", "CODE_PUPPY_DATA_DIR", default=_default_home()
            )

        try:
            config_dir = env_path(
                "PUPPY_CONFIG_DIR",
                "CODE_PUPPY_CONFIG_DIR",
                default=legacy_config.CONFIG_DIR,
            )
        except Exception:
            config_dir = env_path(
                "PUPPY_CONFIG_DIR", "CODE_PUPPY_CONFIG_DIR", default=_default_home()
            )

        try:
            config_file = Path(legacy_config.CONFIG_FILE)
        except Exception:
            config_file = config_dir / "puppy.cfg"

        try:
            models_file = Path(legacy_config.MODELS_FILE)
        except Exception:
            models_file = data_dir / "models.json"
    else:
        # No legacy config — use env vars with hardcoded defaults
        data_dir = env_path(
            "PUPPY_DATA_DIR", "CODE_PUPPY_DATA_DIR", default=_default_home()
        )
        config_dir = env_path(
            "PUPPY_CONFIG_DIR", "CODE_PUPPY_CONFIG_DIR", default=_default_home()
        )
        config_file = config_dir / "puppy.cfg"
        models_file = data_dir / "models.json"

    # Sessions dir is derived from data_dir
    sessions_dir = env_path("PUPPY_SESSIONS_DIR", default=data_dir / "sessions")

    # ─────────────────────────────────────────────────────────────
    # Build and return PuppyConfig
    # ─────────────────────────────────────────────────────────────

    return PuppyConfig(
        # Paths
        data_dir=data_dir,
        config_dir=config_dir,
        config_file=config_file,
        sessions_dir=sessions_dir,
        models_file=models_file,
        # Agent / Model
        default_agent=resolve_str(
            ("PUPPY_DEFAULT_AGENT",), "default_agent", "code-puppy", **resolver_ctx
        ),
        default_model=resolve_str(
            ("PUPPY_DEFAULT_MODEL", "CODE_PUPPY_DEFAULT_MODEL"),
            "model",
            "claude-opus-4-6",
            **resolver_ctx,
        ),
        # Concurrency (from parallel task)
        max_concurrent_runs=resolve_int(
            ("PUPPY_MAX_CONCURRENT_RUNS", "CODE_PUPPY_MAX_CONCURRENT_RUNS"),
            "max_concurrent_runs",
            2,
            min_val=1,
            max_val=100,
            **resolver_ctx,
        ),
        allow_parallel_runs=resolve_bool(
            ("PUPPY_ALLOW_PARALLEL_RUNS", "CODE_PUPPY_ALLOW_PARALLEL_RUNS"),
            "allow_parallel_runs",
            True,
            **resolver_ctx,
        ),
        run_wait_timeout=_env_optional_float(
            "PUPPY_RUN_WAIT_TIMEOUT",
            "CODE_PUPPY_RUN_WAIT_TIMEOUT",
            default=600.0,
        ),
        # Messaging / UI
        ws_history_maxlen=resolve_int(
            ("PUPPY_WS_HISTORY_MAXLEN",),
            "ws_history_maxlen",
            200,
            min_val=10,
            max_val=10000,
            **resolver_ctx,
        ),
        ws_history_ttl_seconds=resolve_int(
            ("PUPPY_WS_HISTORY_TTL_SECONDS",),
            "ws_history_ttl_seconds",
            3600,
            min_val=0,
            max_val=86400 * 7,  # Max 1 week
            **resolver_ctx,
        ),
        # Feature flags
        session_logger_enabled=resolve_bool(
            ("PUPPY_SESSION_LOGGER", "CODE_PUPPY_SESSION_LOGGER"),
            "session_logger_enabled",
            False,
            **resolver_ctx,
        ),
        enable_dbos=resolve_bool(
            ("PUPPY_ENABLE_DBOS", "CODE_PUPPY_ENABLE_DBOS"),
            "enable_dbos",
            True,
            **resolver_ctx,
        ),
        enable_streaming=resolve_bool(
            ("PUPPY_ENABLE_STREAMING",),
            "enable_streaming",
            True,
            **resolver_ctx,
        ),
        enable_agent_memory=resolve_bool(
            ("PUPPY_ENABLE_AGENT_MEMORY",),
            "enable_agent_memory",
            False,
            **resolver_ctx,
        ),
        free_threading_enabled=resolve_bool(
            ("PUP_FREE_THREADING",),
            "free_threading",
            False,
            **resolver_ctx,
        ),
        # UI / Behavior
        temperature=resolve_float(
            ("PUPPY_TEMPERATURE",),
            "temperature",
            0.0,
            min_val=0.0,
            max_val=2.0,
            **resolver_ctx,
        ),
        # UNIFIED: Use constants.SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT (50_000)
        # This aligns with config.py get_protected_token_count() default.
        # See documentation for unification rationale.
        protected_token_count=resolve_int(
            ("PUPPY_PROTECTED_TOKEN_COUNT",),
            "protected_token_count",
            SUMMARIZATION_ABSOLUTE_PROTECTED_DEFAULT,
            min_val=0,
            max_val=100000,
            **resolver_ctx,
        ),
        message_limit=resolve_int(
            ("PUPPY_MESSAGE_LIMIT",),
            "message_limit",
            100,
            min_val=10,
            max_val=10000,
            **resolver_ctx,
        ),
        compaction_strategy=resolve_str(
            ("PUPPY_COMPACTION_STRATEGY",),
            "compaction_strategy",
            "summarize",
            **resolver_ctx,
        ),
        compaction_threshold=resolve_float(
            ("PUPPY_COMPACTION_THRESHOLD",),
            "compaction_threshold",
            0.85,
            min_val=0.5,
            max_val=0.95,
            **resolver_ctx,
        ),
        # Summarization / Compaction (deepagents port)
        summarization_trigger_fraction=resolve_float(
            ("PUPPY_SUMMARIZATION_TRIGGER_FRACTION",),
            "summarization_trigger_fraction",
            0.85,
            min_val=0.5,
            max_val=0.95,
            **resolver_ctx,
        ),
        summarization_keep_fraction=resolve_float(
            ("PUPPY_SUMMARIZATION_KEEP_FRACTION",),
            "summarization_keep_fraction",
            0.10,
            min_val=0.05,
            max_val=0.50,
            **resolver_ctx,
        ),
        summarization_pretruncate_enabled=resolve_bool(
            ("PUPPY_SUMMARIZATION_PRETRUNCATE_ENABLED",),
            "summarization_pretruncate_enabled",
            True,
            **resolver_ctx,
        ),
        summarization_arg_max_length=resolve_int(
            ("PUPPY_SUMMARIZATION_ARG_MAX_LENGTH",),
            "summarization_arg_max_length",
            500,
            min_val=100,
            max_val=10000,
            **resolver_ctx,
        ),
        summarization_history_offload_enabled=resolve_bool(
            ("PUPPY_SUMMARIZATION_HISTORY_OFFLOAD_ENABLED",),
            "summarization_history_offload_enabled",
            False,
            **resolver_ctx,
        ),
        summarization_history_dir=env_path(
            "PUPPY_SUMMARIZATION_HISTORY_DIR",
            default=data_dir / "history",
        ),
        # Debug / Logging
        debug=resolve_bool(
            ("PUPPY_DEBUG", "CODE_PUPPY_DEBUG", "DEBUG"),
            "debug",
            False,
            **resolver_ctx,
        ),
        log_level=resolve_str(
            ("PUPPY_LOG_LEVEL", "CODE_PUPPY_LOG_LEVEL", "LOG_LEVEL"),
            "log_level",
            "INFO",
            **resolver_ctx,
        ),
        # Identity
        puppy_name=resolve_str(("PUPPY_NAME",), "puppy_name", "Puppy", **resolver_ctx),
        owner_name=resolve_str(
            ("PUPPY_OWNER_NAME", "CODE_PUPPY_OWNER"),
            "owner_name",
            "Master",
            **resolver_ctx,
        ),
    )


def get_puppy_config() -> PuppyConfig:
    """Return cached singleton (lazy init).

    The first call loads and caches the config. Subsequent calls return
    the same instance for efficiency.

    Returns:
        The cached PuppyConfig instance.

    Example:
        >>> cfg = get_puppy_config() # Loads on first call
        >>> cfg2 = get_puppy_config() # Same instance
        >>> assert cfg is cfg2
    """
    global _cached_config
    if _cached_config is None:
        with _cache_lock:
            if _cached_config is None:
                _cached_config = load_puppy_config()
    return _cached_config


def reload_puppy_config() -> PuppyConfig:
    """Force reload (for tests or after puppy.cfg edits).

    Clears the singleton cache and returns a fresh config loaded
    from current environment and puppy.cfg.

    Returns:
        A fresh PuppyConfig instance.

    Example:
        >>> # After editing puppy.cfg
        >>> cfg = reload_puppy_config()
    """
    global _cached_config
    with _cache_lock:
        _cached_config = load_puppy_config()
    return _cached_config


def reset_puppy_config_for_tests() -> None:
    """Clear the cache (test helper).

    Resets the singleton cache so that the next call to `get_puppy_config()`
    will load fresh. Use this in test fixtures for isolation.

    Example:
        >>> # In a pytest fixture
        >>> def setup_teardown():
        ... reset_puppy_config_for_tests()
        ... yield
        ... reset_puppy_config_for_tests()
    """
    global _cached_config
    with _cache_lock:
        _cached_config = None
