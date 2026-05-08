"""Typed configuration dataclasses for code_puppy.

This module provides the `PuppyConfig` dataclass — an ADDITIVE typed layer
over the existing dict-based `config.py`. Both APIs coexist; use whichever
fits your call site better.

Examples:
    >>> # Load typed config (singleton)
    >>> from code_puppy.config_package import get_puppy_config
    >>> cfg = get_puppy_config()
    >>> print(cfg.data_dir)
    >>> print(cfg.default_model)

    >>> # Reload after config edits
    >>> cfg = reload_puppy_config()

    >>> # Convert to dict for legacy consumers
    >>> config_dict = cfg.to_dict()
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Fields that should be redacted in __repr__ (exact field name matching)
_SENSITIVE_FIELDS: frozenset[str] = frozenset(
    {
        "puppy_token",
        "api_key",
        "secret",
        "password",
        "token",
    }
)


# Suffixes that indicate a field should be redacted (for exact suffix matching)
_SENSITIVE_SUFFIXES: frozenset[str] = frozenset(
    {
        "_token",
        "_api_key",
        "_secret",
        "_password",
    }
)


@dataclass(slots=True, frozen=True)
class PuppyConfig:
    """Typed settings for code_puppy.

    This is an ADDITIVE typed layer over the existing dict-based config.py.
    Both APIs coexist; use whichever fits your call site better.

    All fields are required (no dataclass defaults) — defaults come from
    the loader, making it the single source of truth for default values.

    This dataclass is FROZEN — instances are immutable. Attempts to
    modify fields after creation will raise FrozenInstanceError.

    Load via:
        >>> from code_puppy.config_package import get_puppy_config
        >>> cfg = get_puppy_config()

    Attributes:
        # Paths
        data_dir: Root directory for data files
        config_dir: Directory containing configuration files
        config_file: Path to the main puppy.cfg file
        sessions_dir: Directory for session logs
        models_file: Path to models.json

        # Agent / model defaults
        default_agent: Default agent name (e.g., "code-puppy")
        default_model: Default model name (e.g., "claude-opus-4-6")

        # Concurrency (matches parallel task keys)
        max_concurrent_runs: Maximum concurrent agent runs
        allow_parallel_runs: Whether to allow parallel execution
        run_wait_timeout: Timeout for waiting on runs (None = no timeout)

        # Messaging / UI
        ws_history_maxlen: Max WebSocket history entries for SSE replay
        ws_history_ttl_seconds: TTL for abandoned session history (0 = disabled)

        # Feature flags
        session_logger_enabled: Enable session logging
        enable_dbos: Enable DBOS integration
        enable_streaming: Enable SSE streaming responses
        enable_agent_memory: Enable agent memory features
        free_threading_enabled: Whether free-threaded Python (no-GIL) is active

        # UI / behavior
        temperature: Default temperature for model calls
        protected_token_count: Tokens to protect during compaction
        message_limit: Max messages per conversation
        compaction_strategy: Strategy for context compaction
        compaction_threshold: Threshold (0.0-1.0) triggering compaction

        # Summarization / compaction (deepagents port)
        summarization_trigger_fraction: Fraction of context triggering summarization
        summarization_keep_fraction: Fraction of context to preserve
        summarization_pretruncate_enabled: Enable pre-truncation of tool args
        summarization_arg_max_length: Max characters for tool args before truncation
        summarization_history_offload_enabled: Enable history offload to file
        summarization_history_dir: Directory for history offload files

        # Debug / logging
        debug: Debug mode flag
        log_level: Log level (DEBUG, INFO, WARNING, ERROR)

        # Identity
        puppy_name: Display name for the puppy
        owner_name: Display name for the owner
    """

    # ─────────────────────────────────────────────────────────────
    # Paths
    # ─────────────────────────────────────────────────────────────
    data_dir: Path
    config_dir: Path
    config_file: Path
    sessions_dir: Path
    models_file: Path

    # ─────────────────────────────────────────────────────────────
    # Agent / Model Defaults
    # ─────────────────────────────────────────────────────────────
    default_agent: str
    default_model: str

    # ─────────────────────────────────────────────────────────────
    # Concurrency (from parallel task)
    # ─────────────────────────────────────────────────────────────
    max_concurrent_runs: int
    allow_parallel_runs: bool
    run_wait_timeout: float | None

    # ─────────────────────────────────────────────────────────────
    # Messaging / UI
    # ─────────────────────────────────────────────────────────────
    ws_history_maxlen: int
    ws_history_ttl_seconds: int

    # ─────────────────────────────────────────────────────────────
    # Feature Flags
    # ─────────────────────────────────────────────────────────────
    session_logger_enabled: bool
    enable_dbos: bool
    enable_streaming: bool
    # DEPRECATED(audit-2026): Legacy config key, use memory_enabled instead
    enable_agent_memory: bool
    free_threading_enabled: bool

    # ─────────────────────────────────────────────────────────────
    # UI / Behavior
    # ─────────────────────────────────────────────────────────────
    temperature: float
    protected_token_count: int
    message_limit: int
    compaction_strategy: str
    compaction_threshold: float

    # ─────────────────────────────────────────────────────────────
    # Summarization / Compaction (deepagents port)
    # ─────────────────────────────────────────────────────────────
    summarization_trigger_fraction: float
    summarization_keep_fraction: float
    summarization_pretruncate_enabled: bool
    summarization_arg_max_length: int
    summarization_history_offload_enabled: bool
    summarization_history_dir: Path

    # ─────────────────────────────────────────────────────────────
    # Debug / Logging
    # ─────────────────────────────────────────────────────────────
    debug: bool
    log_level: str

    # ─────────────────────────────────────────────────────────────
    # Identity
    # ─────────────────────────────────────────────────────────────
    puppy_name: str
    owner_name: str

    def __repr__(self) -> str:
        """Return a safe repr that redacts sensitive fields."""
        fields = []
        for field_name in self.__slots__:
            value = getattr(self, field_name)
            # Check for exact field name match or sensitive suffix match
            field_lower = field_name.lower()
            is_sensitive = field_lower in _SENSITIVE_FIELDS or any(
                field_lower.endswith(suffix) for suffix in _SENSITIVE_SUFFIXES
            )
            if is_sensitive:
                display_value = "***REDACTED***"
            elif isinstance(value, Path):
                display_value = repr(str(value))
            else:
                display_value = repr(value)
            fields.append(f"{field_name}={display_value}")
        return f"{self.__class__.__name__}({', '.join(fields)})"

    def to_dict(self) -> dict[str, Any]:
        """Convert to a plain dict for legacy consumers.

        Returns:
            Dictionary with all field values. Path objects are
            converted to strings for JSON serialization.

        Example:
            >>> cfg = get_puppy_config()
            >>> config_dict = cfg.to_dict()
            >>> print(config_dict["default_model"])
        """
        result: dict[str, Any] = {}
        for field_name in self.__slots__:
            value = getattr(self, field_name)
            # Convert Path objects to strings for JSON serialization
            if isinstance(value, Path):
                value = str(value)
            result[field_name] = value
        return result
