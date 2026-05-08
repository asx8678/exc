"""Configuration module for the agent memory plugin.

This module provides convenient access to memory-related configuration
from puppy.cfg, with proper defaults and validation.

Config keys (in puppy.cfg):
    memory_enabled = false              # OPT-IN, default off (canonical key)
    enable_agent_memory = false         # DEPRECATED: use memory_enabled instead
    memory_debounce_seconds = 30        # Write debounce window (1-300)
    memory_max_facts = 50               # Max facts per agent (1-1000)
    memory_token_budget = 500           # Token budget for injection (100-2000)
    memory_extraction_model = ""        # Optional model override (empty = default)
    memory_min_confidence = 0.5         # Minimum confidence threshold for facts

Example usage:
    >>> from code_puppy.plugins.agent_memory.config import get_config
    >>> config = get_config()
    >>> if config.enabled:
    ...     print(f"Debouncing for {config.debounce_seconds}s")
"""

import logging
from dataclasses import dataclass


@dataclass(frozen=True)
class MemoryConfig:
    """Immutable configuration container for agent memory settings.

    Attributes:
        enabled: Whether agent memory is enabled (default: False - OPT-IN)
        debounce_seconds: Write debounce window in seconds (default: 30)
        max_facts: Maximum facts to store per agent (default: 50)
        token_budget: Token budget for memory injection (default: 500)
        extraction_model: Optional model override for extraction (default: None)
        min_confidence: Minimum confidence threshold for facts (default: 0.5)
        debounce_ms: Debounce window in milliseconds (default: 30000)
        extraction_enabled: Whether LLM fact extraction is enabled (default: True)
        # Signal safeguard settings (code-puppy-eed: memory poisoning fix)
        max_preference_signals_per_fact: int = 10  # Max preference signals per fact
        preference_signal_decay_hours: float = 168.0  # 7 days default decay
        preference_rate_limit_seconds: int = 60  # Min seconds between signals from same session
    """

    enabled: bool = False
    debounce_seconds: int = 30
    max_facts: int = 50
    token_budget: int = 500
    extraction_model: str | None = None
    min_confidence: float = 0.5
    debounce_ms: int = 30000
    extraction_enabled: bool = True
    # Signal safeguard defaults (code-puppy-eed)
    max_preference_signals_per_fact: int = 10
    preference_signal_decay_hours: float = 168.0  # 7 days
    preference_rate_limit_seconds: int = 60


def _get_int(key: str, default: int) -> int:
    """Get integer config value with fallback."""
    # Import inside function to avoid caching reference at module load time
    from code_puppy.config import get_value

    raw = get_value(key)
    if raw is None:
        return default
    try:
        value = int(raw)
    except TypeError, ValueError:
        return default
    return value if value > 0 else default


def _get_bool(key: str, default: bool) -> bool:
    """Get boolean config value with fallback."""
    # Import inside function to avoid caching reference at module load time
    from code_puppy.config import get_value

    raw = get_value(key)
    if raw is None:
        return default
    value = str(raw).strip().lower()
    # Truthy values
    if value in {"1", "true", "yes", "on", "enabled"}:
        return True
    # Falsy values
    if value in {"0", "false", "no", "off", "disabled", ""}:
        return False
    # For any other value, check if it looks truthy
    return value and value not in {
        "0",
        "false",
        "no",
        "off",
        "disabled",
        "none",
        "null",
    }


# Deprecation warning tracking to avoid spam
_deprecated_warning_shown: bool = False


def _warn_deprecated_config() -> None:
    """Warn about deprecated enable_agent_memory config key."""
    global _deprecated_warning_shown
    if _deprecated_warning_shown:
        return
    _deprecated_warning_shown = True
    logger = logging.getLogger(__name__)
    logger.warning(
        "Config key 'enable_agent_memory' is deprecated. Use 'memory_enabled' instead."
    )


def _get_float(key: str, default: float) -> float:
    """Get float config value with fallback."""
    # Import inside function to avoid caching reference at module load time
    from code_puppy.config import get_value

    raw = get_value(key)
    if raw is None:
        return default
    try:
        value = float(raw)
    except TypeError, ValueError:
        return default
    return value if value >= 0 else default


def load_config() -> MemoryConfig:
    """Load memory configuration from config system (Phase 5 style).

    Returns:
        MemoryConfig with loaded values or defaults
    """
    # Import inside function to avoid caching reference at module load time
    from code_puppy.config import get_value

    # Check for deprecated key first
    enabled_via_deprecated = _get_bool("enable_agent_memory", False)
    enabled_via_canonical = _get_bool("memory_enabled", False)

    if enabled_via_deprecated:
        _warn_deprecated_config()

    # Canonical key takes precedence if both are set
    enabled = enabled_via_canonical or enabled_via_deprecated
    debounce_seconds = _get_int("memory_debounce_seconds", 30)

    return MemoryConfig(
        enabled=enabled,
        debounce_seconds=debounce_seconds,
        max_facts=_get_int("memory_max_facts", 50),
        token_budget=_get_int("memory_token_budget", 500),
        extraction_model=get_value("memory_extraction_model") or None,
        min_confidence=_get_float("memory_min_confidence", 0.5),
        debounce_ms=debounce_seconds * 1000,
        extraction_enabled=_get_bool("memory_extraction_enabled", True),
    )


def get_config() -> MemoryConfig:
    """Load and return the current memory configuration (canonical entrypoint).

    Reads all memory-related config keys from puppy.cfg with
    appropriate defaults. This function is lightweight and can
    be called frequently - underlying config reads are cached.

    This is the canonical configuration entrypoint. Use this instead
    of load_config(), which is kept for backward compatibility.

    Returns:
        MemoryConfig with current settings

    Example:
        >>> config = get_config()
        >>> if config.enabled:
        ...     updater = MemoryUpdater(storage, config.debounce_seconds * 1000)
    """
    return load_config()


def is_memory_enabled() -> bool:
    """Quick check if agent memory is enabled.

    This is a convenience function for checks that don't need
    the full configuration object.

    Returns:
        True if memory_enabled (or deprecated enable_agent_memory) is truthy

    Example:
        >>> if is_memory_enabled():
        ...     initialize_memory_system()
    """
    enabled_via_deprecated = _get_bool("enable_agent_memory", False)
    enabled_via_canonical = _get_bool("memory_enabled", False)

    if enabled_via_deprecated:
        _warn_deprecated_config()

    return enabled_via_canonical or enabled_via_deprecated


__all__ = [
    "MemoryConfig",
    "get_config",
    "is_memory_enabled",
    "load_config",
]
