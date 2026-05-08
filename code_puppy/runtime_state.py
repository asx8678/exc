"""Runtime state management for Code Puppy.

This module is a thin Python wrapper that routes all runtime state operations
to the Elixir RuntimeState GenServer. State is stored exclusively in Elixir
with no Python-side caching.

## State Managed

- **Autosave session ID**: Runtime-only session identifier (per-process)
- **Session model name**: Session-local model name cached after first read from config
- **Session start time**: When the current session began
- **Ephemeral caches**: System prompt, tool defs, context overhead, model name, etc.

## Migration Note

This module has been migrated from a dual-path implementation (Elixir-first
with python fallback) to a pure thin wrapper that routes exclusively to
Elixir. The public API remains unchanged for backward compatibility.

## Cache Invalidation

Cache invalidation operations (invalidate_caches, invalidate_all_token_caches,
invalidate_system_prompt_cache) are routed to the Elixir RuntimeState
GenServer via the transport. These mirror the per-agent invalidation in
AgentRuntimeState but operate on the global singleton.
"""

import os
import threading
from typing import Any

from code_puppy.elixir_transport import ElixirTransportError

# opt-in degraded mode lock for thread-safe degraded-mode state access
_DEGRADED_STATE_LOCK = threading.Lock()

# Transport error types caught for degraded-mode fallback
_TRANSPORT_ERRORS = (
    ElixirTransportError,
    OSError,
    BrokenPipeError,
    ConnectionError,
    TimeoutError,
)


def _degraded() -> bool:
    return os.environ.get("PUP_ALLOW_ELIXIR_DEGRADED") == "1"


def _log_degraded(method: str, exc: BaseException) -> None:
    import logging

    logging.getLogger(__name__).warning(
        "Elixir transport unavailable during %s: %s",
        method,
        exc,
    )


def _send_request(method: str, params: dict) -> dict:
    """Send a JSON-RPC request via the Elixir transport."""
    transport = _get_transport()
    return transport._send_request(method, params)


def _get_transport():
    """Get the shared transport singleton from elixir_transport_helpers."""
    from code_puppy.elixir_transport_helpers import get_transport

    return get_transport()


# =============================================================================
# Backward Compatibility Stubs
# =============================================================================

_CURRENT_AUTOSAVE_ID: str | None = None
_SESSION_MODEL: str | None = None


# =============================================================================
# Autosave Session State
# =============================================================================


def get_current_autosave_id() -> str:
    """Get or create the current autosave session ID for this process."""
    try:
        return _send_request("runtime_get_autosave_id", {})["autosave_id"]
    except _TRANSPORT_ERRORS:
        if _degraded():
            with _DEGRADED_STATE_LOCK:
                global _CURRENT_AUTOSAVE_ID
                if _CURRENT_AUTOSAVE_ID is None:
                    from datetime import datetime

                    _CURRENT_AUTOSAVE_ID = datetime.now().strftime("%Y%m%d_%H%M%S")
                return _CURRENT_AUTOSAVE_ID
        raise


def rotate_autosave_id() -> str:
    """Force a new autosave session ID and return it."""
    try:
        return _send_request("runtime_rotate_autosave_id", {})["autosave_id"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("rotate_autosave_id", exc)
            with _DEGRADED_STATE_LOCK:
                global _CURRENT_AUTOSAVE_ID
                from datetime import datetime

                _CURRENT_AUTOSAVE_ID = datetime.now().strftime("%Y%m%d_%H%M%S")
                return _CURRENT_AUTOSAVE_ID
        raise


def get_current_autosave_session_name() -> str:
    """Return the full session name used for autosaves (no file extension)."""
    try:
        return _send_request("runtime_get_autosave_session_name", {})["session_name"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_autosave_session_name", exc)
            with _DEGRADED_STATE_LOCK:
                from datetime import datetime

                return "auto_session_%s" % (
                    _CURRENT_AUTOSAVE_ID or datetime.now().strftime("%Y%m%d_%H%M%S")
                )
        raise


def set_current_autosave_from_session_name(session_name: str) -> str:
    """Set the current autosave ID based on a full session name."""
    try:
        return _send_request(
            "runtime_set_autosave_from_session", {"session_name": session_name}
        )["autosave_id"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_autosave_from_session", exc)
            with _DEGRADED_STATE_LOCK:
                global _CURRENT_AUTOSAVE_ID
                if session_name.startswith("auto_session_"):
                    _CURRENT_AUTOSAVE_ID = session_name[len("auto_session_") :]
                else:
                    _CURRENT_AUTOSAVE_ID = session_name
                return _CURRENT_AUTOSAVE_ID
        raise


def reset_autosave_id() -> None:
    """Reset the autosave ID to None (primarily for testing)."""
    try:
        _send_request("runtime_reset_autosave_id", {})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("reset_autosave_id", exc)
            with _DEGRADED_STATE_LOCK:
                global _CURRENT_AUTOSAVE_ID
                _CURRENT_AUTOSAVE_ID = None
            return
        raise


# =============================================================================
# Session Model State
# =============================================================================


def get_session_model() -> str | None:
    """Get the cached session model name, or None if not yet initialized."""
    try:
        return _send_request("runtime_get_session_model", {})["session_model"]
    except _TRANSPORT_ERRORS:
        if _degraded():
            _log_degraded("get_session_model", Exception("degraded"))
            with _DEGRADED_STATE_LOCK:
                return _SESSION_MODEL
        raise


def set_session_model(model: str | None) -> None:
    """Set the session-local model name."""
    try:
        _send_request("runtime_set_session_model", {"model": model})
    except _TRANSPORT_ERRORS:
        if _degraded():
            with _DEGRADED_STATE_LOCK:
                global _SESSION_MODEL
                _SESSION_MODEL = model
            return
        raise


def reset_session_model() -> None:
    """Reset the session-local model cache (primarily for testing)."""
    try:
        _send_request("runtime_reset_session_model", {})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("reset_session_model", exc)
            with _DEGRADED_STATE_LOCK:
                global _SESSION_MODEL
                _SESSION_MODEL = None
            return
        raise


# =============================================================================
# Utility Functions
# =============================================================================


def finalize_autosave_session() -> str:
    """Persist the current autosave snapshot and rotate to a fresh session.

    Best-effort and never raises. Always calls auto_save_session_if_enabled()
    before rotating, preserving the autosave-before-rotation contract in both
    normal and degraded paths. The Elixir RuntimeState handles ID rotation
    after the Python-side save completes.
    """
    # Preserve autosave-before-rotation: save FIRST in all paths
    try:
        from code_puppy.config import auto_save_session_if_enabled

        auto_save_session_if_enabled()
    except Exception as save_exc:
        import logging

        logging.getLogger(__name__).warning(
            "auto_save_session_if_enabled failed during finalize: %s",
            save_exc,
        )
    try:
        return _send_request("runtime_finalize_autosave_session", {})["autosave_id"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("finalize_autosave_session", exc)
            try:
                return rotate_autosave_id()
            except Exception:
                from datetime import datetime

                return datetime.now().strftime("%Y%m%d_%H%M%S_fallback")
        raise


def get_state() -> dict[str, Any]:
    """Get full runtime state for introspection."""
    try:
        result = _send_request("runtime_get_state", {})
        return {
            "autosave_id": result["autosave_id"],
            "session_model": result["session_model"],
            "session_start_time": result["session_start_time"],
        }
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_state", exc)
            from datetime import datetime

            with _DEGRADED_STATE_LOCK:
                return {
                    "autosave_id": _CURRENT_AUTOSAVE_ID
                    or datetime.now().strftime("%Y%m%d_%H%M%S"),
                    "session_model": _SESSION_MODEL,
                    "session_start_time": datetime.now().isoformat() + "Z",
                }
        raise


# =============================================================================
# Cache Invalidation
# =============================================================================


def invalidate_caches() -> None:
    """Invalidate ephemeral caches. Call when model/tool config changes."""
    try:
        _send_request("runtime_invalidate_caches", {})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("invalidate_caches", exc)
            return
        raise


def invalidate_all_token_caches() -> None:
    """Invalidate ALL token-related caches as a group.

    Must be called when any of these change:
    - System prompt (custom prompts, /prompts command)
    - Tool definitions (agent reload, MCP changes)
    - Model (model switch)
    - Puppy rules file (AGENTS.md changes)
    """
    try:
        _send_request("runtime_invalidate_all_token_caches", {})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("invalidate_all_token_caches", exc)
            return
        raise


def invalidate_system_prompt_cache() -> None:
    """Invalidate cached system prompt when plugin state changes."""
    try:
        _send_request("runtime_invalidate_system_prompt_cache", {})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("invalidate_system_prompt_cache", exc)
            return
        raise


# =============================================================================
# Cache Getter / Setter API
#
# These mirror the per-instance cache properties on Python's AgentRuntimeState
# but are routed through the Elixir RuntimeState GenServer.
# =============================================================================


def get_cached_system_prompt() -> str | None:
    """Get the cached system prompt string, or None if not yet computed."""
    try:
        return _send_request("runtime_get_cached_system_prompt", {})[
            "cached_system_prompt"
        ]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_cached_system_prompt", exc)
            return None
        raise


def set_cached_system_prompt(prompt: str | None) -> None:
    """Set the cached system prompt string."""
    try:
        _send_request("runtime_set_cached_system_prompt", {"prompt": prompt})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_cached_system_prompt", exc)
            return
        raise


def get_cached_tool_defs() -> list[dict[str, Any]] | None:
    """Get the cached tool definitions list, or None if not yet computed."""
    try:
        return _send_request("runtime_get_cached_tool_defs", {})["cached_tool_defs"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_cached_tool_defs", exc)
            return None
        raise


def set_cached_tool_defs(defs: list[dict[str, Any]] | None) -> None:
    """Set the cached tool definitions list."""
    try:
        _send_request("runtime_set_cached_tool_defs", {"tool_defs": defs})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_cached_tool_defs", exc)
            return
        raise


def get_model_name_cache() -> str | None:
    """Get the cached model name, or None if not yet resolved."""
    try:
        return _send_request("runtime_get_model_name_cache", {})["model_name_cache"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_model_name_cache", exc)
            return None
        raise


def set_model_name_cache(name: str | None) -> None:
    """Set the cached model name."""
    try:
        _send_request("runtime_set_model_name_cache", {"model_name": name})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_model_name_cache", exc)
            return
        raise


def get_delayed_compaction_requested() -> bool:
    """Get whether delayed compaction has been requested."""
    try:
        return _send_request("runtime_get_delayed_compaction_requested", {})[
            "delayed_compaction_requested"
        ]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_delayed_compaction_requested", exc)
            return False
        raise


def set_delayed_compaction_requested(value: bool) -> None:
    """Set the delayed compaction requested flag."""
    try:
        _send_request("runtime_set_delayed_compaction_requested", {"value": value})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_delayed_compaction_requested", exc)
            return
        raise


def get_tool_ids_cache() -> Any:
    """Get the per-invocation tool IDs cache."""
    try:
        return _send_request("runtime_get_tool_ids_cache", {})["tool_ids_cache"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_tool_ids_cache", exc)
            return None
        raise


def set_tool_ids_cache(cache: Any) -> None:
    """Set the per-invocation tool IDs cache."""
    try:
        _send_request("runtime_set_tool_ids_cache", {"cache": cache})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_tool_ids_cache", exc)
            return
        raise


def get_cached_context_overhead() -> int | None:
    """Get the cached context overhead estimate, or None if not yet computed."""
    try:
        return _send_request("runtime_get_cached_context_overhead", {})[
            "cached_context_overhead"
        ]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_cached_context_overhead", exc)
            return None
        raise


def set_cached_context_overhead(value: int | None) -> None:
    """Set the cached context overhead estimate."""
    try:
        _send_request("runtime_set_cached_context_overhead", {"value": value})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_cached_context_overhead", exc)
            return
        raise


def get_resolved_model_components_cache() -> dict[str, Any] | None:
    """Get the resolved model components cache map, or None if not yet computed."""
    try:
        return _send_request("runtime_get_resolved_model_components_cache", {})[
            "resolved_model_components_cache"
        ]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_resolved_model_components_cache", exc)
            return None
        raise


def set_resolved_model_components_cache(cache: dict[str, Any] | None) -> None:
    """Set the resolved model components cache map."""
    try:
        _send_request("runtime_set_resolved_model_components_cache", {"cache": cache})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_resolved_model_components_cache", exc)
            return
        raise


def get_puppy_rules_cache() -> str | None:
    """Get the cached puppy rules content, or None if not yet loaded.

    Mirrors Python's AgentRuntimeState.puppy_rules — the lazy-loaded content
    of AGENTS.md / puppy rules file, cached to avoid re-reading from disk.
    """
    try:
        return _send_request("runtime_get_puppy_rules_cache", {})["puppy_rules_cache"]
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("get_puppy_rules_cache", exc)
            return None
        raise


def set_puppy_rules_cache(rules: str | None) -> None:
    """Set the cached puppy rules content."""
    try:
        _send_request("runtime_set_puppy_rules_cache", {"rules": rules})
    except _TRANSPORT_ERRORS as exc:
        if _degraded():
            _log_degraded("set_puppy_rules_cache", exc)
            return
        raise


# =============================================================================
# Diagnostics
# =============================================================================


def is_using_elixir() -> bool:
    """Check if the Elixir backend is currently connected."""
    try:
        _send_request("ping", {})
        return True
    except Exception:
        return False
