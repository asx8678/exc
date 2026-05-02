"""Feature toggles, debug flags, and environment configuration.

Mirrors ``CodePuppyControl.Config.Debug`` in the Elixir runtime.

Centralizes all boolean feature flags and debug-related settings from
``puppy.cfg``. Each getter has a documented default that matches the
Python/Elixir behavior.

Config keys in puppy.cfg:

- ``yolo_mode`` — auto-approve all actions (default true)
- ``allow_recursion`` — allow recursive agent calls (default true)
- ``enable_dbos`` — enable DBOS workflow engine (default true)
- ``enable_pack_agents`` — enable pack agents (default false)
- ``enable_universal_constructor`` — enable dynamic tool creation (default true)
- ``enable_streaming`` — enable SSE streaming (default true)
- ``enable_agent_memory`` — enable cross-session agent memory (default false)
- ``http2`` — enable HTTP/2 for httpx clients (default false)
- ``subagent_verbose`` — verbose output for sub-agents (default false)
- ``disable_mcp`` — skip MCP server loading (default false)
- ``safety_permission_level`` — risk threshold (default ``"medium"``)
- ``enable_user_plugins`` — enable user plugin loading (default true)
- ``allowed_user_plugins`` — comma-separated plugin allowlist
"""

from __future__ import annotations

import os
from pathlib import Path

from code_puppy.config.loader import (
    _is_truthy,
    _make_bool_getter,
    _make_int_getter,
    _registered_cache,
    get_value,
    set_config_value,
)

__all__ = [
    "get_yolo_mode",
    "get_allow_recursion",
    "get_use_dbos",
    "set_enable_dbos",
    "get_pack_agents_enabled",
    "PACK_AGENT_NAMES",
    "UC_AGENT_NAMES",
    "get_universal_constructor_enabled",
    "set_universal_constructor_enabled",
    "get_enable_streaming",
    "get_enable_agent_memory",
    "get_adaptive_rendering_enabled",
    "get_post_edit_validation_enabled",
    "get_subagent_verbose",
    "get_http2",
    "set_http2",
    "get_mcp_disabled",
    "get_safety_permission_level",
    "get_enable_user_plugins",
    "get_allowed_user_plugins",
    "load_api_keys_to_environment",
    "get_api_key",
    "set_api_key",
    # ADR-003 / feature toggles
    "get_elixir_message_shadow_mode_enabled",
    "get_enable_gitignore_filtering",
]


# ---------------------------------------------------------------------------
# YOLO mode
# ---------------------------------------------------------------------------


@_registered_cache
def get_yolo_mode() -> bool:
    """Return True if YOLO mode is enabled (auto-approve actions, default true)."""
    return _is_truthy(get_value("yolo_mode"), default=True)


# ---------------------------------------------------------------------------
# Recursion
# ---------------------------------------------------------------------------


get_allow_recursion = _make_bool_getter(
    "allow_recursion",
    default=True,
    doc="Return True if recursive agent calls are allowed (default True).",
)


# ---------------------------------------------------------------------------
# DBOS
# ---------------------------------------------------------------------------


@_registered_cache
def get_use_dbos() -> bool:
    """Return True if DBOS should be used.

    Returns True only when BOTH conditions are met:
    1. ``enable_dbos`` is not explicitly set to false in puppy.cfg (default: true)
    2. The dbos package is actually installed
    """
    if not _is_truthy(get_value("enable_dbos"), default=True):
        return False
    try:
        import dbos as _dbos  # noqa: F401

        return True
    except ImportError:
        return False


def set_enable_dbos(enabled: bool) -> None:
    """Enable or disable DBOS via config."""
    set_config_value("enable_dbos", "true" if enabled else "false")


# ---------------------------------------------------------------------------
# Pack agents
# ---------------------------------------------------------------------------

PACK_AGENT_NAMES = frozenset(
    ["pack-leader", "shepherd", "terrier", "watchdog", "retriever"]
)

UC_AGENT_NAMES = frozenset(["helios"])

get_pack_agents_enabled = _make_bool_getter(
    "enable_pack_agents",
    default=False,
    doc="""Return True if pack agents are enabled (default False).""",
)


# ---------------------------------------------------------------------------
# Universal Constructor
# ---------------------------------------------------------------------------


get_universal_constructor_enabled = _make_bool_getter(
    "enable_universal_constructor",
    default=True,
    doc="""Return True if the Universal Constructor is enabled (default True).""",
)


def set_universal_constructor_enabled(enabled: bool) -> None:
    """Enable or disable the Universal Constructor."""
    set_config_value("enable_universal_constructor", "true" if enabled else "false")


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------


get_enable_streaming = _make_bool_getter(
    "enable_streaming",
    default=True,
    doc="Return True if SSE streaming is enabled (default True).",
)


# ---------------------------------------------------------------------------
# Agent memory
# ---------------------------------------------------------------------------


@_registered_cache
def get_enable_agent_memory() -> bool:
    """Return True if agent memory is enabled (default False).

    DEPRECATED(audit-2026): Use memory_enabled instead.
    """
    return _is_truthy(get_value("enable_agent_memory"), default=False)


get_memory_debounce_seconds = _make_int_getter(
    "memory_debounce_seconds",
    default=30,
    min_val=1,
    max_val=300,
    doc="Return memory write debounce in seconds (default 30).",
)

get_memory_max_facts = _make_int_getter(
    "memory_max_facts",
    default=50,
    min_val=1,
    max_val=1000,
    doc="Return max facts per agent (default 50).",
)

get_memory_token_budget = _make_int_getter(
    "memory_token_budget",
    default=500,
    min_val=100,
    max_val=2000,
    doc="Return token budget for memory injection (default 500).",
)


@_registered_cache
def get_memory_extraction_model() -> str | None:
    """Return the optional model override for memory extraction."""
    return get_value("memory_extraction_model")


# ---------------------------------------------------------------------------
# Adaptive rendering
# ---------------------------------------------------------------------------


@_registered_cache
def get_adaptive_rendering_enabled() -> bool:
    """Return True if adaptive payload rendering is enabled (default True)."""
    from code_puppy.config_package.env_helpers import env_bool

    env_val = env_bool("PUPPY_ADAPTIVE_RENDERING", default=True)
    if not env_val:
        return False
    return _is_truthy(get_value("adaptive_rendering"), default=True)


# ---------------------------------------------------------------------------
# Post-edit validation
# ---------------------------------------------------------------------------


@_registered_cache
def get_post_edit_validation_enabled() -> bool:
    """Return True if post-edit syntax validation is enabled (default True)."""
    from code_puppy.config_package.env_helpers import env_bool

    env_val = env_bool("PUPPY_POST_EDIT_VALIDATION", default=True)
    if not env_val:
        return False
    return _is_truthy(get_value("enable_post_edit_validation"), default=True)


# ---------------------------------------------------------------------------
# Sub-agent verbose
# ---------------------------------------------------------------------------


get_subagent_verbose = _make_bool_getter(
    "subagent_verbose",
    default=False,
    doc="Return True if sub-agent verbose output is enabled (default False).",
)


# ---------------------------------------------------------------------------
# HTTP/2
# ---------------------------------------------------------------------------


get_http2 = _make_bool_getter(
    "http2",
    default=False,
    doc="Return True if HTTP/2 is enabled (default False).",
)


def set_http2(enabled: bool) -> None:
    """Set the http2 configuration value."""
    set_config_value("http2", "true" if enabled else "false")


# ---------------------------------------------------------------------------
# MCP disabled
# ---------------------------------------------------------------------------


get_mcp_disabled = _make_bool_getter(
    "disable_mcp",
    default=False,
    doc="Return True if MCP is disabled (default False).",
)


# ---------------------------------------------------------------------------
# Safety permission level
# ---------------------------------------------------------------------------


_VALID_SAFETY_LEVELS = frozenset({"none", "low", "medium", "high", "critical"})


@_registered_cache
def get_safety_permission_level() -> str:
    """Return the safety permission level (default ``"medium"``)."""
    val = get_value("safety_permission_level")
    if val:
        normalized = str(val).strip().lower()
        if normalized in _VALID_SAFETY_LEVELS:
            return normalized
    return "medium"


# ---------------------------------------------------------------------------
# User plugin security
# ---------------------------------------------------------------------------


get_enable_user_plugins = _make_bool_getter(
    "enable_user_plugins",
    default=True,
    doc="Return True if user plugin loading is enabled (default True).",
)


@_registered_cache
def get_allowed_user_plugins() -> list[str]:
    """Return the list of allowed user plugin names from config."""
    val = get_value("allowed_user_plugins")
    if not val:
        return []
    return [name.strip() for name in val.split(",") if name.strip()]


# ---------------------------------------------------------------------------
# API key management
# ---------------------------------------------------------------------------


def get_api_key(key_name: str) -> str:
    """Get an API key from puppy.cfg."""
    return get_value(key_name) or ""


def set_api_key(key_name: str, value: str) -> None:
    """Set an API key in puppy.cfg."""
    set_config_value(key_name, value)


# ---------------------------------------------------------------------------
# Elixir shadow mode
# ---------------------------------------------------------------------------


get_elixir_message_shadow_mode_enabled = _make_bool_getter(
    "enable_elixir_message_shadow_mode",
    default=False,
    doc="""Return True if Elixir message shadow mode is enabled (default False).

    When enabled, both Python and Elixir execute message operations
    and results are compared for divergence detection.
    """,
)


# ---------------------------------------------------------------------------
# Gitignore filtering
# ---------------------------------------------------------------------------


get_enable_gitignore_filtering = _make_bool_getter(
    "enable_gitignore_filtering",
    default=False,
    doc="""Return True if gitignore-based file filtering is enabled (default False).

    When enabled, file operations respect .gitignore patterns.
    Higher-risk flag: requires explicit opt-in.
    """,
)


# Code Puppy environment variable allowlist
_CODEPUPPY_ENV_ALLOWLIST: set[str] = {
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "CEREBRAS_API_KEY",
    "SYN_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_ENDPOINT",
    "OPENROUTER_API_KEY",
    "ZAI_API_KEY",
    "GITHUB_TOKEN",
    "FIREWORKS_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "PUP_DEBUG",
    "PUP_MODEL",
    "PUP_AGENT",
    "PUPPY_DEFAULT_AGENT",
    "PUPPY_DEFAULT_MODEL",
    "PUPPY_TEMPERATURE",
    "PUPPY_MESSAGE_LIMIT",
    "PUPPY_PROTECTED_TOKEN_COUNT",
    "PUP_DISABLE_CALLBACK_PLUGIN_LOADING",
    "CODE_PUPPY_SKIP_TUTORIAL",
    "CODE_PUPPY_NO_TUI",
    "CODE_PUPPY_NO_COLOR",
    "CODE_PUPPY_FORCE_COLOR",
    "CODE_PUPPY_CODE_THEME",
    "CODE_PUPPY_ALLOWED_ORIGINS",
    "CODE_PUPPY_DISABLE_RETRY_TRANSPORT",
    "CODE_PUPPY_BRIDGE",
    "PUPPY_ADAPTIVE_RENDERING",
    "PUPPY_POST_EDIT_VALIDATION",
    "PUPPY_WS_HISTORY_TTL_SECONDS",
    "PUPPY_WS_HISTORY_MAXLEN",
    "CODE_PUPPY_BRIDGE_HOST",
    "NO_VERSION_UPDATE",
}


def _load_env_allowlisted(env_file: Path, allowlist: set[str]) -> None:
    """Load only allowlisted keys from .env file into os.environ."""
    if not env_file.exists():
        return
    try:
        from dotenv import dotenv_values
    except ImportError:
        return
    values = dotenv_values(env_file)
    for key in allowlist:
        if key in values and key not in os.environ:
            os.environ[key] = values[key]


def load_api_keys_to_environment() -> None:
    """Load all API keys from .env and puppy.cfg into environment variables.

    Priority: .env > puppy.cfg > existing env vars.
    Security: Only allowlisted Code Puppy env vars are loaded from .env.
    """
    api_key_names = [
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
        "ANTHROPIC_API_KEY",
        "CEREBRAS_API_KEY",
        "SYN_API_KEY",
        "AZURE_OPENAI_API_KEY",
        "AZURE_OPENAI_ENDPOINT",
        "OPENROUTER_API_KEY",
        "ZAI_API_KEY",
    ]

    env_file = Path.cwd() / ".env"
    _load_env_allowlisted(env_file, _CODEPUPPY_ENV_ALLOWLIST)

    for key_name in api_key_names:
        if key_name not in os.environ or not os.environ[key_name]:
            value = get_api_key(key_name)
            if value:
                os.environ[key_name] = value
