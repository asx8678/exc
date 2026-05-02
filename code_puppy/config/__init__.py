"""Code Puppy configuration package — split-by-concern facade.

This package replaces the monolithic ``config.py`` (2694 lines) with
focused sub-modules that each stay under 600 lines. The ``__init__.py``
re-exports all public names for **full backward compatibility** — existing
imports like ``from code_puppy.config import get_value`` continue to work.

Module layout (mirrors ``CodePuppyControl.Config.*`` in Elixir):

| Module        | Elixir counterpart              | Responsibility                            |
|---------------|----------------------------------|--------------------------------------------|
| ``loader``    | ``Config.Loader`` + ``Config.Writer`` | INI parser, cache, get/set/reset      |
| ``paths``     | ``Config.Paths`` + ``Config.Isolation`` | XDG paths, isolation guards         |
| ``models``    | ``Config.Models``               | Model name, per-model settings, pinning   |
| ``agents``    | ``Config.Agents``               | Default agent, personalization, dirs       |
| ``tui``       | ``Config.TUI``                  | Banner/diff colors, display flags          |
| ``limits``    | ``Config.Limits``               | Compaction, token budgets, timeouts        |
| ``debug``     | ``Config.Debug``                | Feature toggles, YOLO, API keys           |
| ``cache``     | ``Config.Cache``                | Auto-save, WS history, command history     |
| ``mcp``       | (partial Config facade)         | MCP server config loading                  |

ADR-003 Dual-Home Isolation
----------------------------

When running as pup-ex (``PUP_EX_HOME`` set), all writes go to
``~/.code_puppy_ex/`` and NEVER to ``~/.code_puppy/``. This is enforced
by ``code_puppy.config_paths.assert_write_allowed`` — every setter in
this package calls it before writing.

The Elixir runtime (``CodePuppyControl.Config.Isolation``) enforces the
same guard on its side. Python code that needs Elixir config data should
use the bridge access pattern::

    from code_puppy.plugins.elixir_bridge import is_connected, call_method
    if is_connected():
        result = call_method('code_context.explore_file', {'file_path': path})
"""

# ruff: noqa: F401 — re-export facade; all imports are re-exported for backward compatibility

from __future__ import annotations

# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------
from code_puppy.config.agents import (
    get_default_agent,
    get_owner_name,
    get_project_agents_directory,
    get_puppy_name,
    get_puppy_token,
    get_user_agents_directory,
    set_default_agent,
    set_puppy_token,
)

# ---------------------------------------------------------------------------
# Cache / Session
# ---------------------------------------------------------------------------
from code_puppy.config.cache import (
    auto_save_session_if_enabled,
    finalize_autosave_session,
    get_auto_save_session,
    get_current_autosave_id,
    get_current_autosave_session_name,
    get_max_saved_sessions,
    get_ws_history_maxlen,
    get_ws_history_ttl_seconds,
    initialize_command_history_file,
    rotate_autosave_id,
    save_command_to_history,
    set_auto_save_session,
    set_current_autosave_from_session_name,
    set_max_saved_sessions,
)

# ---------------------------------------------------------------------------
# Debug / Feature toggles
# ---------------------------------------------------------------------------
from code_puppy.config.debug import (
    PACK_AGENT_NAMES,
    UC_AGENT_NAMES,
    get_adaptive_rendering_enabled,
    get_allow_recursion,
    get_allowed_user_plugins,
    get_api_key,
    get_elixir_message_shadow_mode_enabled,
    get_enable_agent_memory,
    get_enable_gitignore_filtering,
    get_enable_streaming,
    get_enable_user_plugins,
    get_http2,
    get_mcp_disabled,
    get_memory_debounce_seconds,
    get_memory_extraction_model,
    get_memory_max_facts,
    get_memory_token_budget,
    get_pack_agents_enabled,
    get_post_edit_validation_enabled,
    get_safety_permission_level,
    get_subagent_verbose,
    get_universal_constructor_enabled,
    get_use_dbos,
    get_yolo_mode,
    load_api_keys_to_environment,
    set_api_key,
    set_enable_dbos,
    set_http2,
    set_universal_constructor_enabled,
)

# ---------------------------------------------------------------------------
# Limits
# ---------------------------------------------------------------------------
from code_puppy.config.limits import (
    get_bus_request_timeout_seconds,
    get_compaction_strategy,
    get_compaction_threshold,
    get_max_run_tokens,
    get_max_session_tokens,
    get_message_limit,
    get_protected_token_count,
    get_resume_message_count,
    get_summarization_arg_max_length,
    get_summarization_history_dir,
    get_summarization_history_offload_enabled,
    get_summarization_keep_fraction,
    get_summarization_pretruncate_enabled,
    get_summarization_return_head_chars,
    get_summarization_return_max_length,
    get_summarization_return_tail_chars,
    get_summarization_trigger_fraction,
)

# ---------------------------------------------------------------------------
# Core loader (foundation — must be first)
# ---------------------------------------------------------------------------
from code_puppy.config.loader import (
    _CACHED_GETTERS,
    _TRUTHY_VALUES,
    DEFAULT_SECTION,
    REQUIRED_KEYS,
    ConfigState,
    _get_config,
    _get_xdg_dir,
    _invalidate_config,
    _is_truthy,
    _make_bool_getter,
    _make_float_getter,
    _make_int_getter,
    _registered_cache,
    ensure_config_exists,
    get_config_keys,
    get_config_state,
    get_default_config_keys,
    get_value,
    reset_value,
    set_config_value,
    set_value,
)

# ---------------------------------------------------------------------------
# MCP
# ---------------------------------------------------------------------------
from code_puppy.config.mcp import load_mcp_server_configs

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
from code_puppy.config.models import (
    _validate_model_exists,
    clear_agent_pinned_model,
    clear_model_cache,
    clear_model_settings,
    get_agent_pinned_model,
    get_agents_pinned_to_model,
    get_all_agent_pinned_models,
    get_all_model_settings,
    get_effective_model_settings,
    get_effective_seed,
    get_effective_temperature,
    get_effective_top_p,
    get_global_model_name,
    get_model_context_length,
    get_model_setting,
    get_openai_reasoning_effort,
    get_openai_reasoning_summary,
    get_openai_verbosity,
    get_temperature,
    model_supports_setting,
    reset_session_model,
    set_agent_pinned_model,
    set_model_name,
    set_model_setting,
    set_openai_reasoning_effort,
    set_openai_reasoning_summary,
    set_openai_verbosity,
    set_temperature,
)

# ---------------------------------------------------------------------------
# Paths (lazy path constants + isolation guards)
# ---------------------------------------------------------------------------
from code_puppy.config.paths import (
    _LAZY_PATH_FACTORIES,
    _LAZY_PATH_OVERRIDES,
    ConfigIsolationViolation,
    _path_agents_dir,
    _path_autosave_dir,
    _path_command_history_file,
    _path_config_file,
    _path_default_sqlite_file,
    _path_mcp_servers_file,
    _path_skills_dir,
    _xdg_cache_dir,
    _xdg_config_dir,
    _xdg_data_dir,
    _xdg_state_dir,
    resolve_path,
    safe_append,
    safe_atomic_write,
    safe_mkdir_p,
    safe_rm,
    safe_rm_rf,
    safe_write,
    with_sandbox,
)

# ---------------------------------------------------------------------------
# TUI
# ---------------------------------------------------------------------------
from code_puppy.config.tui import (
    DEFAULT_BANNER_COLORS,
    get_all_banner_colors,
    get_banner_color,
    get_diff_addition_color,
    get_diff_context_lines,
    get_diff_deletion_color,
    get_grep_output_verbose,
    get_suppress_informational_messages,
    get_suppress_thinking_messages,
    reset_all_banner_colors,
    reset_banner_color,
    set_banner_color,
    set_diff_addition_color,
    set_diff_deletion_color,
    set_suppress_informational_messages,
    set_suppress_thinking_messages,
)

# Also re-export config_paths top-level functions that config.py used to expose
from code_puppy.config_paths import (
    assert_write_allowed,
    cache_dir,
    config_dir,
    data_dir,
    home_dir,
    is_pup_ex,
    legacy_home_dir,
    python_home_dir,
    state_dir,
)

# ---------------------------------------------------------------------------
# Diff highlight style (no-op legacy)
# ---------------------------------------------------------------------------


def set_diff_highlight_style(style: str) -> None:
    """Set the diff highlight style. No-op — always uses 'highlight' mode."""
    pass


# ---------------------------------------------------------------------------
# Lazy path constant access via __getattr__ (PEP 562)
# ---------------------------------------------------------------------------

# These names are expected by external code doing:
#   from code_puppy.config import CONFIG_FILE
#   config.CONFIG_FILE
# They resolve lazily to respect pup-ex isolation.

# All lazy path constant names from _LAZY_PATH_FACTORIES (excludes
# underscored internals like _DEFAULT_SQLITE_FILE).
_LAZY_EXPORTS = {k for k in _LAZY_PATH_FACTORIES if not k.startswith("_")}


def __getattr__(name: str):
    """Lazy path resolution for external attribute access (PEP 562)."""
    if name in _LAZY_PATH_FACTORIES:
        return _LAZY_PATH_FACTORIES[name]()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# ---------------------------------------------------------------------------
# Public API exports
# ---------------------------------------------------------------------------

__all__ = sorted(
    # ── Lazy path constants (resolved via __getattr__) ────────────
    list(_LAZY_EXPORTS)
    # ── Core loader ───────────────────────────────────────────────
    + [
        "ConfigState",
        "DEFAULT_SECTION",
        "REQUIRED_KEYS",
        "get_config_state",
        "get_value",
        "set_value",
        "set_config_value",
        "reset_value",
        "get_config_keys",
        "get_default_config_keys",
        "ensure_config_exists",
    ]
    # ── Models ────────────────────────────────────────────────────
    + [
        "set_model_name",
        "get_global_model_name",
        "model_supports_setting",
        "clear_model_cache",
        "reset_session_model",
        "get_model_context_length",
        "get_openai_reasoning_effort",
        "set_openai_reasoning_effort",
        "get_openai_reasoning_summary",
        "set_openai_reasoning_summary",
        "get_openai_verbosity",
        "set_openai_verbosity",
        "get_temperature",
        "set_temperature",
        "get_effective_temperature",
        "get_effective_model_settings",
        "get_model_setting",
        "set_model_setting",
        "get_all_model_settings",
        "clear_model_settings",
        "get_agent_pinned_model",
        "set_agent_pinned_model",
        "clear_agent_pinned_model",
        "get_agents_pinned_to_model",
        "get_all_agent_pinned_models",
        "get_effective_top_p",
        "get_effective_seed",
    ]
    # ── Agents ────────────────────────────────────────────────────
    + [
        "get_default_agent",
        "set_default_agent",
        "get_puppy_name",
        "get_owner_name",
        "get_user_agents_directory",
        "get_project_agents_directory",
        "get_puppy_token",
        "set_puppy_token",
    ]
    # ── TUI ───────────────────────────────────────────────────────
    + [
        "DEFAULT_BANNER_COLORS",
        "get_banner_color",
        "set_banner_color",
        "get_all_banner_colors",
        "reset_banner_color",
        "reset_all_banner_colors",
        "get_diff_addition_color",
        "set_diff_addition_color",
        "get_diff_deletion_color",
        "set_diff_deletion_color",
        "get_diff_context_lines",
        "get_suppress_thinking_messages",
        "set_suppress_thinking_messages",
        "get_suppress_informational_messages",
        "set_suppress_informational_messages",
        "get_grep_output_verbose",
    ]
    # ── Limits ────────────────────────────────────────────────────
    + [
        "get_protected_token_count",
        "get_compaction_threshold",
        "get_compaction_strategy",
        "get_resume_message_count",
        "get_message_limit",
        "get_bus_request_timeout_seconds",
        "get_max_session_tokens",
        "get_max_run_tokens",
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
    # ── Debug / Feature toggles ──────────────────────────────────
    + [
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
        "get_memory_debounce_seconds",
        "get_memory_max_facts",
        "get_memory_token_budget",
        "get_memory_extraction_model",
        "get_elixir_message_shadow_mode_enabled",
        "get_enable_gitignore_filtering",
    ]
    # ── Cache / Session ──────────────────────────────────────────
    + [
        "get_auto_save_session",
        "set_auto_save_session",
        "get_max_saved_sessions",
        "set_max_saved_sessions",
        "get_ws_history_maxlen",
        "get_ws_history_ttl_seconds",
        "save_command_to_history",
        "initialize_command_history_file",
        "get_current_autosave_id",
        "rotate_autosave_id",
        "get_current_autosave_session_name",
        "set_current_autosave_from_session_name",
        "auto_save_session_if_enabled",
        "finalize_autosave_session",
    ]
    # ── MCP ──────────────────────────────────────────────────────
    + [
        "load_mcp_server_configs",
    ]
    # ── Isolation guards (from paths + config_paths) ─────────────
    + [
        "ConfigIsolationViolation",
        "safe_write",
        "safe_mkdir_p",
        "safe_rm",
        "safe_rm_rf",
        "safe_atomic_write",
        "safe_append",
        "with_sandbox",
        "resolve_path",
        "is_pup_ex",
        "home_dir",
        "legacy_home_dir",
        "python_home_dir",
        "config_dir",
        "data_dir",
        "cache_dir",
        "state_dir",
        "assert_write_allowed",
    ]
    # ── Defined in __init__ ──────────────────────────────────────
    + [
        "set_diff_highlight_style",
    ]
    # ── Underscored but public legacy names (kept for backward compat) ──
    + [
        "_validate_model_exists",
    ]
)
