"""Callback registration for session_logger plugin.

Registers callbacks to track agent runs and write structured session archives:
- agent_run_start: Initialize new SessionWriter for the session
- agent_run_end: Finalize session manifest
- pre_tool_call: Record tool call start (for handling missing post_tool_call)
- post_tool_call: Record tool call completion
- shutdown: Cleanup any unfinalized sessions

Configuration (puppy.cfg [puppy] section):
    session_logger_enabled = false   # Enable/disable (default: false - opt-in)

Session logs are written to the canonical sessions_dir (typically
~/.code_puppy/sessions). There is no separate session_logger_dir setting.
"""

import asyncio
import logging
import threading
import uuid
from pathlib import Path
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_warning
from code_puppy.utils.path_safety import (
    PathSafetyError,
    safe_path_component,
    verify_contained,
)

from .config import get_session_logger_dir, get_session_logger_enabled
from .writer import SessionWriter

logger = logging.getLogger(__name__)

# Thread-safe session tracking: session_id -> SessionWriter
_lock = threading.Lock()
_sessions: dict[str, SessionWriter] = {}
_session_tool_call_ids: dict[
    str, dict[str, str]
] = {}  # session_id -> (tool_key -> call_id)


def _get_session_id(session_id: str | None) -> str:
    """Generate or validate session ID.

    Args:
        session_id: Optional session identifier

    Returns:
        Valid session ID string
    """
    if session_id:
        return str(session_id)
    return f"session-{uuid.uuid4().hex[:8]}"


def _get_session_dir(base_dir: Path, session_id: str) -> Path:
    """Get the session-specific directory.

    Creates a timestamped subdirectory for better organization.
    Format: {base_dir}/{timestamp}_{short_id}

    Uses shared path_safety utilities to sanitize the session identifier
    component to prevent path traversal attacks.

    Args:
        base_dir: Base sessions directory
        session_id: Session identifier (will be sanitized)

    Returns:
        Path to session-specific directory (verified contained within base_dir)

    Raises:
        PathSafetyError: If session_id contains unsafe characters that could
            lead to path traversal.
    """
    from datetime import datetime, timezone

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    # Sanitize the timestamp component (should be safe, but defense-in-depth)
    safe_timestamp = safe_path_component(timestamp, max_len=15)

    # Sanitize the session ID component - this is user/LLM-provided input
    short_id = session_id[:8] if len(session_id) > 8 else session_id
    try:
        safe_id = safe_path_component(short_id, max_len=8)
    except PathSafetyError as exc:
        # If session_id is unsafe, hash it to create a safe identifier
        import hashlib

        safe_id = hashlib.md5(short_id.encode()).hexdigest()[:8]
        logger.warning(f"Session ID contained unsafe characters, using hash: {exc}")

    dir_name = f"{safe_timestamp}_{safe_id}"
    session_dir = base_dir / dir_name

    # Verify the constructed path stays within base_dir (defense-in-depth)
    try:
        return verify_contained(session_dir, base_dir)
    except PathSafetyError as exc:
        logger.error(f"Session directory path verification failed: {exc}")
        # Fallback: use a hash-based name that is guaranteed safe
        safe_name = f"session_{uuid.uuid4().hex[:8]}"
        fallback_dir = base_dir / safe_name
        return verify_contained(fallback_dir, base_dir)


async def _on_agent_run_start(
    agent_name: str, model_name: str, session_id: str | None = None
) -> None:
    """Initialize session logging when an agent run starts.

    Args:
        agent_name: Name of the agent starting
        model_name: Name of the model being used
        session_id: Optional session identifier
    """
    # Check if enabled (configurable at runtime)
    if not get_session_logger_enabled():
        return

    try:
        sid = _get_session_id(session_id)
        base_dir = get_session_logger_dir()
        session_dir = _get_session_dir(base_dir, sid)

        writer = SessionWriter(
            session_dir=session_dir,
            agent_name=agent_name,
            model_name=model_name,
            session_id=sid,
        )

        with _lock:
            _sessions[sid] = writer
            _session_tool_call_ids[sid] = {}

        # FIX ijx: Wrap blocking I/O in asyncio.to_thread()
        await asyncio.to_thread(
            writer.append_log, f"Agent '{agent_name}' started with model '{model_name}'"
        )
        logger.debug(f"Session logging started for session {sid}")

    except Exception as e:
        logger.warning(f"Failed to initialize session logging: {e}")
        # Graceful degradation: emit warning but don't crash
        try:
            emit_warning(f"Session logging failed to initialize: {e}")
        except Exception:
            pass


async def _on_agent_run_end(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    success: bool = True,
    error: Exception | None = None,
    response_text: str | None = None,
    metadata: dict | None = None,
    **kwargs,
) -> None:
    """Finalize session logging when an agent run ends.

    Args:
        agent_name: Name of the agent that finished
        model_name: Name of the model that was used
        session_id: Optional session identifier
        success: Whether the run completed successfully
        error: Exception if the run failed
        response_text: The final text response from the agent
        metadata: Optional dict with additional context
    """
    # Check if enabled
    if not get_session_logger_enabled():
        return

    try:
        sid = _get_session_id(session_id)

        with _lock:
            writer = _sessions.pop(sid, None)
            _session_tool_call_ids.pop(sid, None)

        if writer is None:
            logger.debug(f"No session writer found for session {sid}")
            return

        # Log completion - FIX ijx: Wrap blocking I/O in asyncio.to_thread()
        status = "completed successfully" if success else "failed"
        await asyncio.to_thread(writer.append_log, f"Agent run {status}")
        if response_text:
            preview = (
                response_text[:200] + "..."
                if len(response_text) > 200
                else response_text
            )
            await asyncio.to_thread(writer.append_log, f"Response: {preview}")

        # Convert exception to string for manifest
        error_str = str(error) if error else None
        # FIX ijx: Wrap blocking I/O in asyncio.to_thread()
        await asyncio.to_thread(writer.finalize, success=success, error=error_str)

        logger.debug(f"Session logging finalized for session {sid}")

    except Exception as e:
        logger.warning(f"Failed to finalize session logging: {e}")
        # Graceful degradation: don't crash on logging errors


async def _on_pre_tool_call(
    tool_name: str, tool_args: dict, context: Any = None
) -> None:
    """Record tool call start.

    Stores pending tool call info to handle cases where post_tool_call
    might not fire (e.g., if tool raises exception).

    Args:
        tool_name: Name of the tool being called
        tool_args: Arguments being passed to the tool
        context: Optional context data
    """
    # Check if enabled
    if not get_session_logger_enabled():
        return

    try:
        # Try to get session_id from context
        sid = _get_session_id_from_context(context)
        if sid is None:
            return  # Not part of a tracked session

        with _lock:
            writer = _sessions.get(sid)
            call_ids = _session_tool_call_ids.get(sid)

        if writer is None or call_ids is None:
            return

        # FIX ijx: Wrap blocking I/O in asyncio.to_thread()
        call_id = await asyncio.to_thread(
            writer.record_pre_tool_call, tool_name, tool_args, context
        )

        # FIX a57: Use RunContext metadata instead of hash-based key for correlation
        # This prevents race conditions when concurrent identical tool calls occur
        try:
            from code_puppy.run_context import get_current_run_context

            run_ctx = get_current_run_context()
            if run_ctx is not None:
                # Store call_id in RunContext metadata for correlation with post_tool_call
                run_ctx.metadata["_session_logger_call_id"] = call_id
        except Exception:
            pass  # Fall through to legacy hash-based correlation

        # Legacy hash-based correlation as fallback (may have race conditions)
        tool_key = f"{tool_name}:{hash(str(tool_args))}"

        with _lock:
            if sid in _session_tool_call_ids:
                _session_tool_call_ids[sid][tool_key] = call_id

    except Exception as e:
        logger.debug(f"Failed to record pre_tool_call: {e}")
        # Non-critical: don't crash on logging errors


async def _on_post_tool_call(
    tool_name: str,
    tool_args: dict,
    result: Any,
    duration_ms: float,
    context: Any = None,
) -> None:
    """Record tool call completion.

    Args:
        tool_name: Name of the tool that was called
        tool_args: Arguments that were passed to the tool
        result: The result returned by the tool
        duration_ms: Execution time in milliseconds
        context: Optional context data
    """
    # Check if enabled
    if not get_session_logger_enabled():
        return

    try:
        # Try to get session_id from context
        sid = _get_session_id_from_context(context)
        if sid is None:
            return  # Not part of a tracked session

        # FIX a57: Try RunContext metadata first for race-safe correlation
        call_id = None
        try:
            from code_puppy.run_context import get_current_run_context

            run_ctx = get_current_run_context()
            if run_ctx is not None:
                call_id = run_ctx.metadata.pop("_session_logger_call_id", None)
        except Exception:
            pass

        # Fallback to hash-based correlation if RunContext method failed
        if call_id is None:
            tool_key = f"{tool_name}:{hash(str(tool_args))}"
            with _lock:
                call_id = _session_tool_call_ids.get(sid, {}).pop(tool_key, None)

        with _lock:
            writer = _sessions.get(sid)

        if writer is None:
            return

        # FIX ijx: Wrap blocking I/O in asyncio.to_thread()
        await asyncio.to_thread(
            writer.append_tool_call,
            tool_name=tool_name,
            tool_args=tool_args,
            result=result,
            duration_ms=duration_ms,
            call_id=call_id,
        )

        # Also append to main log for human readability
        status = "completed" if result is not None else "returned None"
        await asyncio.to_thread(
            writer.append_log,
            f"Tool '{tool_name}' {status} ({duration_ms:.1f}ms)",
        )

    except Exception as e:
        logger.debug(f"Failed to record post_tool_call: {e}")
        # Non-critical: don't crash on logging errors


def _get_session_id_from_context(context: Any) -> str | None:
    """Extract session_id from context.

    Tries multiple sources to find the session ID.

    Args:
        context: Context data that may contain session info

    Returns:
        Session ID string or None if not found
    """
    if context is None:
        return None

    # Try context attributes
    if hasattr(context, "session_id"):
        sid = getattr(context, "session_id", None)
        if sid:
            return str(sid)

    # Try context dict
    if isinstance(context, dict):
        for key in ("agent_session_id", "session_id", "sid"):
            if key in context:
                return str(context[key])

    # Try run_context
    try:
        from code_puppy.run_context import get_current_run_context

        ctx = get_current_run_context()
        if ctx and ctx.session_id:
            return str(ctx.session_id)
    except Exception:
        pass

    return None


def _on_shutdown() -> None:
    """Cleanup any unfinalized sessions on shutdown.

    Called during application shutdown to ensure all sessions are
    properly finalized even if agent_run_end didn't fire.
    """
    if not get_session_logger_enabled():
        return

    try:
        with _lock:
            sessions_to_finalize = list(_sessions.items())
            _sessions.clear()
            _session_tool_call_ids.clear()

        for sid, writer in sessions_to_finalize:
            try:
                logger.warning(f"Finalizing unfinalized session {sid} during shutdown")
                writer.append_log(
                    "Session finalized during shutdown (may indicate abnormal termination)"
                )
                writer.finalize(success=None, error="Session finalized during shutdown")
            except Exception as e:
                logger.warning(f"Failed to finalize session {sid} during shutdown: {e}")

    except Exception as e:
        logger.warning(f"Error during session shutdown cleanup: {e}")


# Register callbacks
def _register():
    """Register all session logger callbacks."""
    register_callback("agent_run_start", _on_agent_run_start)
    register_callback("agent_run_end", _on_agent_run_end)
    register_callback("pre_tool_call", _on_pre_tool_call)
    register_callback("post_tool_call", _on_post_tool_call)
    register_callback("shutdown", _on_shutdown)

    if get_session_logger_enabled():
        logger.info("Session logger plugin loaded (enabled)")
    else:
        logger.debug(
            "Session logger plugin loaded (disabled - set session_logger_enabled=true to enable)"
        )


# Auto-register on import
_register()
