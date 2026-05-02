"""Resource limits and compaction configuration.

Mirrors ``CodePuppyControl.Config.Limits`` in the Elixir runtime.

Manages token budgets, compaction thresholds, message limits, and
timeout values from ``puppy.cfg``.

Config keys in puppy.cfg:

- ``protected_token_count`` — tokens exempt from compaction (default 50000)
- ``compaction_threshold`` — context fraction that triggers compaction (0.85)
- ``compaction_strategy`` — ``"summarization"`` or ``"truncation"``
- ``resume_message_count`` — messages to show on resume (default 50)
- ``message_limit`` — max agent steps (default 100)
- ``max_session_tokens`` — hard token budget per session (default 0 = disabled)
- ``max_run_tokens`` — hard token budget per run (default 0 = disabled)
- ``bus_request_timeout_seconds`` — timeout for user input (default 300.0)
- Summarization config keys
"""

from __future__ import annotations

from pathlib import Path

from code_puppy.config.loader import (
    _make_bool_getter,
    _make_float_getter,
    _make_int_getter,
    _registered_cache,
    get_value,
)
from code_puppy.config.models import get_model_context_length

__all__ = [
    "get_protected_token_count",
    "get_compaction_threshold",
    "get_compaction_strategy",
    "get_resume_message_count",
    "get_message_limit",
    "get_bus_request_timeout_seconds",
    "get_max_session_tokens",
    "get_max_run_tokens",
    # Summarization
    "get_summarization_trigger_fraction",
    "get_summarization_keep_fraction",
    "get_summarization_pretruncate_enabled",
    "get_summarization_arg_max_length",
    "get_summarization_return_max_length",
    "get_summarization_return_head_chars",
    "get_summarization_return_tail_chars",
    "get_summarization_history_offload_enabled",
    "get_summarization_history_dir",
]


# ---------------------------------------------------------------------------
# Protected tokens
# ---------------------------------------------------------------------------


from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache


@thread_safe_lru_cache(maxsize=256)
def get_protected_token_count() -> int:
    """Return the user-configured protected token count for compaction.

    Defaults to 50000. Enforces that protected tokens don't exceed 75%
    of model context length.
    """
    val = get_value("protected_token_count")
    try:
        model_context_length = get_model_context_length()
        max_protected_tokens = int(model_context_length * 0.75)
        configured_value = int(val) if val else 50000
        return max(1000, min(configured_value, max_protected_tokens))
    except ValueError, TypeError:
        model_context_length = get_model_context_length()
        max_protected_tokens = int(model_context_length * 0.75)
        return min(50000, max_protected_tokens)


# ---------------------------------------------------------------------------
# Compaction
# ---------------------------------------------------------------------------


get_resume_message_count = _make_int_getter(
    "resume_message_count",
    default=50,
    min_val=1,
    max_val=100,
    doc="""Return number of messages to display when resuming (default 50).""",
)


get_compaction_threshold = _make_float_getter(
    "compaction_threshold",
    default=0.85,
    min_val=0.5,
    max_val=0.95,
    doc="""Return compaction threshold as float (default 0.85).""",
)


get_bus_request_timeout_seconds = _make_float_getter(
    "bus_request_timeout_seconds",
    default=300.0,
    min_val=10.0,
    max_val=3600.0,
    doc="""Return bus request timeout in seconds (default 300.0).""",
)


@_registered_cache
def get_compaction_strategy() -> str:
    """Return compaction strategy: ``"summarization"`` or ``"truncation"``."""
    val = get_value("compaction_strategy")
    if val and val.lower() in ["summarization", "truncation"]:
        return val.lower()
    return "summarization"


# ---------------------------------------------------------------------------
# Message limits
# ---------------------------------------------------------------------------


@_registered_cache
def get_message_limit(default: int = 100) -> int:
    """Return the user-configured message/request limit (default 100)."""
    val = get_value("message_limit")
    try:
        return int(val) if val else default
    except ValueError, TypeError:
        return default


# ---------------------------------------------------------------------------
# Token budgets
# ---------------------------------------------------------------------------


get_max_session_tokens = _make_int_getter(
    "max_session_tokens",
    0,
    min_val=0,
    doc="Hard token budget per session (0=disabled).",
)

get_max_run_tokens = _make_int_getter(
    "max_run_tokens",
    0,
    min_val=0,
    doc="Hard token budget per run (0=disabled).",
)


# ---------------------------------------------------------------------------
# Summarization config (deepagents port)
# ---------------------------------------------------------------------------


@_registered_cache
def get_summarization_trigger_fraction() -> float:
    """Return fraction of context that triggers summarization (default 0.85)."""
    val = get_value("summarization_trigger_fraction")
    try:
        result = float(val) if val else 0.85
        return max(0.5, min(0.95, result))
    except ValueError, TypeError:
        return 0.85


@_registered_cache
def get_summarization_keep_fraction() -> float:
    """Return fraction of context to keep (default 0.10)."""
    val = get_value("summarization_keep_fraction")
    try:
        result = float(val) if val else 0.10
        return max(0.05, min(0.50, result))
    except ValueError, TypeError:
        return 0.10


get_summarization_pretruncate_enabled = _make_bool_getter(
    "summarization_pretruncate_enabled",
    default=True,
    doc="Enable pre-truncation of tool args before summarization (default True).",
)


get_summarization_arg_max_length = _make_int_getter(
    "summarization_arg_max_length",
    default=500,
    min_val=100,
    max_val=10000,
    doc="Max characters for tool args before truncation (default 500).",
)


get_summarization_return_max_length = _make_int_getter(
    "summarization_return_max_length",
    default=5000,
    min_val=500,
    max_val=100000,
    doc="Max characters for tool return before truncation (default 5000).",
)


get_summarization_return_head_chars = _make_int_getter(
    "summarization_return_head_chars",
    default=500,
    min_val=100,
    max_val=5000,
    doc="Characters to preserve from start of truncated return (default 500).",
)


get_summarization_return_tail_chars = _make_int_getter(
    "summarization_return_tail_chars",
    default=200,
    min_val=50,
    max_val=2000,
    doc="Characters to preserve from end of truncated return (default 200).",
)


get_summarization_history_offload_enabled = _make_bool_getter(
    "summarization_history_offload_enabled",
    default=False,
    doc="Enable history offload to file (default False).",
)


def get_summarization_history_dir() -> Path:
    """Return directory for history offload files.

    ADR-003: Defaults to <active_home>/history/ (respects isolation).
    """
    from code_puppy.config_paths import home_dir as _home_dir

    val = get_value("summarization_history_dir")
    if val:
        return Path(val).expanduser()
    return _home_dir() / "history"
