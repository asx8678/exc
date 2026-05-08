"""Callback registration for loop detection.

This module registers callbacks that detect repetitive tool call patterns
and prevent agents from getting stuck in infinite loops.

Configuration (puppy.cfg [puppy] section):
    loop_detection_warn = 3       # Threshold to inject warning (default: 3)
    loop_detection_stop = 5       # Threshold to block tool calls (default: 5)
    loop_detection_exempt_tools = wait, sleep  # Tools that can repeat safely

Detection strategy:
  1. Hash each tool call (name + normalized args) using MD5 truncated to 12 chars.
  2. Track recent hashes per session in a sliding window (maxlen=50).
  3. At warn threshold: inject system-level warning via post_tool_call hook.
  4. At hard threshold: block the tool call via fail-closed pre_tool_call hook.
"""

import hashlib
import json
import logging
import threading
import time
from collections import defaultdict, deque
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.config import get_value
from code_puppy.messaging import emit_warning
from code_puppy.permission_decision import Deny
from code_puppy.run_context import get_current_run_context

logger = logging.getLogger(__name__)

# Default configuration values
_DEFAULT_WARN_THRESHOLD = 3
_DEFAULT_HARD_THRESHOLD = 5
_DEFAULT_HISTORY_SIZE = 50
_DEFAULT_EXEMPT_TOOLS = frozenset({"wait", "sleep"})

# Thread-safe storage for per-session loop detection state
_lock = threading.Lock()
_session_history: dict[str, deque[str]] = defaultdict(
    lambda: deque(maxlen=_DEFAULT_HISTORY_SIZE)
)
_session_warned: dict[str, set[str]] = defaultdict(set)

# TTL-based config cache — re-reads config every _CONFIG_TTL seconds
_CONFIG_TTL = 5.0  # seconds
_config_cache: dict[str, Any] = {}
_config_cache_time: float = 0.0


def _invalidate_config_cache() -> None:
    """Invalidate the config cache, forcing a re-read on next access."""
    global _config_cache_time
    _config_cache_time = 0.0


def _get_exempt_tools() -> frozenset[str]:
    """Read exempt tools from puppy.cfg (cached with TTL).

    Returns:
        Set of tool names that are allowed to repeat without triggering loop detection.
    """
    global _config_cache, _config_cache_time
    now = time.monotonic()
    if now - _config_cache_time < _CONFIG_TTL and "exempt_tools" in _config_cache:
        return _config_cache["exempt_tools"]

    try:
        exempt_str = get_value("loop_detection_exempt_tools")
        if exempt_str:
            tools = {t.strip() for t in exempt_str.split(",") if t.strip()}
            result = frozenset(tools)
        else:
            result = _DEFAULT_EXEMPT_TOOLS
    except Exception as exc:
        logger.debug("Failed to read loop_detection_exempt_tools config: %s", exc)
        result = _DEFAULT_EXEMPT_TOOLS

    _config_cache["exempt_tools"] = result
    _config_cache_time = now
    return result


def _get_warn_threshold() -> int:
    """Read warn threshold from puppy.cfg (cached with TTL).

    Returns:
        Number of identical tool calls before injecting a warning.
    """
    global _config_cache, _config_cache_time
    now = time.monotonic()
    if now - _config_cache_time < _CONFIG_TTL and "warn_threshold" in _config_cache:
        return _config_cache["warn_threshold"]

    try:
        val = get_value("loop_detection_warn")
        if val:
            result = max(1, int(val))
        else:
            result = _DEFAULT_WARN_THRESHOLD
    except (ValueError, TypeError) as exc:
        logger.debug("Invalid loop_detection_warn config: %s", exc)
        result = _DEFAULT_WARN_THRESHOLD

    _config_cache["warn_threshold"] = result
    _config_cache_time = now
    return result


def _get_hard_threshold() -> int:
    """Read hard/stop threshold from puppy.cfg (cached with TTL).

    Returns:
        Number of identical tool calls before blocking the tool.
    """
    global _config_cache, _config_cache_time
    now = time.monotonic()
    if now - _config_cache_time < _CONFIG_TTL and "hard_threshold" in _config_cache:
        return _config_cache["hard_threshold"]

    try:
        val = get_value("loop_detection_stop")
        if val:
            result = max(1, int(val))
        else:
            result = _DEFAULT_HARD_THRESHOLD
    except (ValueError, TypeError) as exc:
        logger.debug("Invalid loop_detection_stop config: %s", exc)
        result = _DEFAULT_HARD_THRESHOLD

    _config_cache["hard_threshold"] = result
    _config_cache_time = now
    return result


def _normalize_tool_args(tool_args: Any) -> dict[str, Any]:
    """Normalize tool arguments to a stable dict representation.

    Handles cases where args might be passed as JSON strings instead of dicts.

    Args:
        tool_args: The tool arguments (dict, string, or other).

    Returns:
        Normalized dictionary representation of the arguments.
    """
    if isinstance(tool_args, dict):
        return tool_args

    if isinstance(tool_args, str):
        try:
            parsed = json.loads(tool_args)
            if isinstance(parsed, dict):
                return parsed
            return {"_parsed": parsed}
        except json.JSONDecodeError, TypeError, ValueError:
            return {"_raw": tool_args}

    if tool_args is None:
        return {}

    return {"_value": tool_args}


def _stable_tool_key(tool_name: str, args: dict[str, Any]) -> str:
    """Generate a stable key for a tool call based on its name and salient args.

    Args:
        tool_name: The name of the tool.
        args: Normalized tool arguments.

    Returns:
        A stable string key representing this tool call.
    """
    # For read_file, bucket line ranges to avoid false positives on adjacent reads
    if tool_name == "read_file":
        path = args.get("path") or args.get("file_path") or ""
        start_line = args.get("start_line")
        num_lines = args.get("num_lines")

        bucket_size = 200
        try:
            start = int(start_line) if start_line is not None else 1
        except ValueError, TypeError:
            start = 1

        bucket_start = max((start - 1) // bucket_size, 0)

        if num_lines is not None:
            try:
                end = start + int(num_lines)
                bucket_end = max((end - 1) // bucket_size, 0)
                return f"{path}:{bucket_start}-{bucket_end}"
            except ValueError, TypeError:
                pass

        return f"{path}:{bucket_start}"

    # For write_file and str_replace, content matters - hash the full args
    if tool_name in {"write_file", "replace_in_file", "create_file"}:
        return json.dumps(args, sort_keys=True, default=str)

    # For most tools, use salient identifying fields
    salient_fields = (
        "path",
        "file_path",
        "directory",
        "search_string",
        "command",
        "url",
        "pattern",
    )
    stable_args = {k: args[k] for k in salient_fields if args.get(k) is not None}

    if stable_args:
        return json.dumps(stable_args, sort_keys=True, default=str)

    # Fallback: hash all args
    return json.dumps(args, sort_keys=True, default=str)


def _hash_tool_calls(tool_name: str, tool_args: Any) -> str:
    """Create an order-independent multiset hash of a tool call.

    Uses MD5 and truncates to 12 characters for compactness while
    maintaining sufficient collision resistance for loop detection.

    Args:
        tool_name: Name of the tool being called.
        tool_args: Arguments passed to the tool.

    Returns:
        12-character truncated MD5 hash of the normalized tool call.
    """
    args = _normalize_tool_args(tool_args)
    key = _stable_tool_key(tool_name, args)

    # Hash the already-deterministic key directly — _stable_tool_key
    # returns json.dumps(sort_keys=True) output, no need to re-serialize
    blob = f"{tool_name}:{key}"

    # MD5 truncated to 12 chars is sufficient for loop detection (not for security)
    return hashlib.md5(blob.encode(), usedforsecurity=False).hexdigest()[:12]


def _get_session_id(context: Any) -> str:
    """Extract session ID from context for per-session tracking.

    Args:
        context: Optional context data that may contain agent_session_id.

    Returns:
        Session ID string, or "default" if not found.
    """
    if context is not None and hasattr(context, "session_id"):
        sid = getattr(context, "session_id", None)
        if sid:
            return str(sid)

    if isinstance(context, dict):
        session_id = context.get("agent_session_id")
        if session_id:
            return str(session_id)

    # Try to get from run_context if available
    try:
        ctx = get_current_run_context()
        if ctx and ctx.session_id:
            return str(ctx.session_id)
    except Exception:
        pass

    return "default"


def _is_tool_exempt(tool_name: str) -> bool:
    """Check if a tool is exempt from loop detection.

    Args:
        tool_name: Name of the tool to check.

    Returns:
        True if the tool is in the exempt list.
    """
    exempt_tools = _get_exempt_tools()
    return tool_name in exempt_tools


async def _on_pre_tool_call(
    tool_name: str, tool_args: dict[str, Any], context: Any = None
) -> dict[str, Any] | Deny | None:
    """Pre-tool-call callback to detect loops and block at hard threshold.

    This implements fail-closed semantics: if we've seen the same tool call
    too many times in this session, we deny the operation to prevent
    infinite loops.

    Args:
        tool_name: Name of the tool being called.
        tool_args: Arguments being passed to the tool.
        context: Optional context data (may contain agent_session_id).

    Returns:
        Deny object to block the tool call at hard threshold, None otherwise.
    """
    # Skip exempt tools
    if _is_tool_exempt(tool_name):
        return None

    # Skip tools with no args (likely simple getters)
    if not tool_args:
        return None

    session_id = _get_session_id(context)
    call_hash = _hash_tool_calls(tool_name, tool_args)

    with _lock:
        # Get or create history deque for this session
        history = _session_history[session_id]

        # Count occurrences of this hash in history
        count = history.count(call_hash)

        hard_threshold = _get_hard_threshold()

        if count >= hard_threshold - 1:  # -1 because we're about to add it
            tool_names = [tool_name]
            logger.error(
                "Loop hard limit reached — blocking tool call",
                extra={
                    "session_id": session_id,
                    "call_hash": call_hash,
                    "count": count + 1,
                    "tools": tool_names,
                    "threshold": hard_threshold,
                },
            )

            # Calculate remaining calls to block
            calls_until_block = hard_threshold - (count + 1)
            block_msg = (
                f"After {calls_until_block} more identical call(s), tools will be blocked."
                if calls_until_block > 0
                else "Tools will be blocked after this call."
            )

            # Return Deny to block the tool call
            return Deny(
                reason=f"Loop detected: repeated {tool_name} calls exceeded safety limit ({hard_threshold})",
                user_feedback=(
                    f"🛑 LOOP DETECTED: Tool '{tool_name}' has been called {count + 1} times "
                    f"with identical arguments. This looks like an infinite loop.\n\n"
                    f"Please stop calling tools and produce your final answer now. "
                    f"If you cannot complete the task, summarize what you accomplished so far.\n\n"
                    f"To override: add '{tool_name}' to loop_detection_exempt_tools in puppy.cfg "
                    f"or increase loop_detection_stop threshold.\n\n"
                    f"{block_msg}"
                ),
            )

        # Add this call to history
        history.append(call_hash)

    return None


async def _on_post_tool_call(
    tool_name: str,
    tool_args: dict[str, Any],
    result: Any,
    duration_ms: float,
    context: Any = None,
) -> None:
    """Post-tool-call callback to inject warnings at the warn threshold.

    This runs after a tool completes and can inject warning messages
    into the conversation to alert the agent about repetitive behavior.

    Args:
        tool_name: Name of the tool that was called.
        tool_args: Arguments that were passed to the tool.
        result: The result returned by the tool.
        duration_ms: Execution time in milliseconds.
        context: Optional context data.
    """
    # Skip exempt tools
    if _is_tool_exempt(tool_name):
        return

    # Skip tools with no args
    if not tool_args:
        return

    session_id = _get_session_id(context)
    call_hash = _hash_tool_calls(tool_name, tool_args)

    # Variables to capture state for warning emission outside the lock
    should_warn = False
    warning_text = None
    count = 0
    warn_threshold = _get_warn_threshold()

    with _lock:
        # Check if we've already warned for this hash
        warned_hashes = _session_warned[session_id]
        if call_hash in warned_hashes:
            return  # Already warned for this pattern

        # Check count (pre_tool_call already added this call to history)
        history = _session_history.get(session_id)
        if not history:
            return

        count = history.count(call_hash)

        if count >= warn_threshold:
            # Mark as warned so we don't repeat the warning
            warned_hashes.add(call_hash)

            logger.warning(
                "Repetitive tool calls detected — injecting warning",
                extra={
                    "session_id": session_id,
                    "call_hash": call_hash,
                    "count": count,
                    "tool": tool_name,
                    "threshold": warn_threshold,
                },
            )

            # Prepare warning text for emission outside the lock
            hard_threshold = _get_hard_threshold()
            calls_until_block = max(0, hard_threshold - count)
            should_warn = True
            warning_text = (
                f"⚠️ LOOP WARNING: Tool '{tool_name}' has been called {count} times "
                f"with similar arguments. You may be stuck in a loop.\n\n"
                f"Please consider:\n"
                f"  1. Check if you're making progress\n"
                f"  2. Stop calling tools and summarize findings\n"
                f"  3. Ask the user for guidance if blocked\n\n"
                f"After {calls_until_block} more identical call(s), tools will be blocked."
            )

    # Emit warning message to the agent OUTSIDE the lock
    if should_warn and warning_text:
        try:
            emit_warning(warning_text)
        except Exception as exc:
            logger.debug("Failed to emit loop warning: %s", exc)


def reset_loop_detection(session_id: str | None = None) -> None:
    """Clear loop detection state.

    Can be called to reset the tracking for a specific session or all sessions.

    Args:
        session_id: If provided, only clear state for this session.
                   If None, clear all session state.
    """
    with _lock:
        if session_id:
            _session_history.pop(session_id, None)
            _session_warned.pop(session_id, None)
            logger.debug("Reset loop detection for session %s", session_id)
        else:
            _session_history.clear()
            _session_warned.clear()
            logger.debug("Reset loop detection for all sessions")


def get_loop_stats(session_id: str | None = None) -> dict[str, Any]:
    """Get loop detection statistics for debugging/monitoring.

    Args:
        session_id: If provided, get stats for this session only.

    Returns:
        Dictionary with loop detection statistics.
    """
    with _lock:
        if session_id:
            history = _session_history.get(session_id, deque())
            warned = _session_warned.get(session_id, set())
            return {
                "session_id": session_id,
                "history_size": len(history),
                "warned_count": len(warned),
                "unique_hashes": len(set(history)),
            }

        return {
            "total_sessions": len(_session_history),
            "total_history_entries": sum(len(h) for h in _session_history.values()),
            "total_warned_hashes": sum(len(w) for w in _session_warned.values()),
        }


def _on_agent_run_end(agent_name, model_name, session_id=None, *args, **kwargs):
    """Clean up loop detection state when an agent run ends."""
    if session_id:
        reset_loop_detection(str(session_id))


# Register the callbacks
register_callback("pre_tool_call", _on_pre_tool_call)
register_callback("post_tool_call", _on_post_tool_call)
register_callback("agent_run_end", _on_agent_run_end)
register_callback("shutdown", lambda: reset_loop_detection())

logger.info(
    "Loop detection plugin loaded (warn=%d, stop=%d, exempt=%s)",
    _get_warn_threshold(),
    _get_hard_threshold(),
    sorted(_get_exempt_tools()),
)
