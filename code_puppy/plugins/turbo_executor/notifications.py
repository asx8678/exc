"""Turbo Executor Notifications — Visual feedback for batch operations.

Hooks into pre_tool_call and post_tool_call callbacks to detect turbo_execute
tool calls and emit visual progress notifications to the user.
"""

import json
import logging
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info, emit_success, emit_warning

logger = logging.getLogger(__name__)

# Operation type to emoji mapping
_OP_EMOJIS = {
    "list_files": "📂",
    "grep": "🔍",
    "read_files": "📄",
}


def _get_op_emoji(op_type: str) -> str:
    """Get emoji for operation type."""
    return _OP_EMOJIS.get(op_type, "⚡")


def _format_brief_args(op_type: str, args: dict) -> str:
    """Format brief argument summary for an operation."""
    if op_type == "list_files":
        directory = args.get("directory", ".")
        return f"dir={directory}"

    if op_type == "grep":
        search = args.get("search_string", "")
        # Truncate long search strings
        if len(search) > 30:
            search = search[:27] + "..."
        return f"search='{search}'"

    if op_type == "read_files":
        paths = args.get("file_paths", [])
        count = len(paths) if isinstance(paths, list) else 0
        return f"{count} files"

    return ""


def _format_brief_stats(op_type: str, data: dict) -> str:
    """Format brief stats from operation result data."""
    if op_type == "list_files":
        content = data.get("content", "")
        if isinstance(content, str):
            # Count lines (files/directories listed)
            lines = [line for line in content.split("\n") if line.strip()]
            return f"{len(lines)} items"
        return ""

    if op_type == "grep":
        matches = data.get("total_matches", 0)
        return f"{matches} matches"

    if op_type == "read_files":
        successful = data.get("successful_reads", 0)
        total = data.get("total_files", 0)
        return f"{successful}/{total} reads"

    return ""


def _on_pre_tool_call(tool_name: str, tool_args: dict, context: Any = None) -> None:
    """Handle pre_tool_call callback for turbo_execute.

    Emits startup banner when a turbo_execute tool call begins.

    Args:
        tool_name: Name of the tool being called
        tool_args: Arguments passed to the tool (contains plan_json)
        context: Optional context object
    """
    # Ignore non-turbo_execute tool calls
    if tool_name != "turbo_execute":
        return

    try:
        plan_json_str = tool_args.get("plan_json", "{}")
        plan_data = json.loads(plan_json_str)

        plan_id = plan_data.get("id", "unnamed")
        operations = plan_data.get("operations", [])
        num_ops = len(operations)

        # Build operation type summary
        op_counts: dict[str, int] = {}
        for op in operations:
            op_type = op.get("type", "unknown")
            op_counts[op_type] = op_counts.get(op_type, 0) + 1

        summary_parts = []
        for op_type, count in sorted(op_counts.items()):
            emoji = _get_op_emoji(op_type)
            summary_parts.append(f"{emoji} {count} {op_type}")

        summary = ", ".join(summary_parts) if summary_parts else "no operations"

        # Emit startup banner
        emit_info(f"🚀 Turbo Plan '{plan_id}' starting — {num_ops} operations")
        emit_info(f"   {summary}")

    except json.JSONDecodeError as e:
        logger.warning(f"Failed to parse turbo_execute plan_json: {e}")
        emit_info("🚀 Turbo Plan starting — parsing plan...")
    except Exception as e:
        logger.warning(f"Error in turbo_execute pre_tool_call notification: {e}")
        # Fail silently - don't break the actual tool execution


def _on_post_tool_call(
    tool_name: str,
    tool_args: dict,
    result: Any,
    duration_ms: float,
    context: Any = None,
) -> None:
    """Handle post_tool_call callback for turbo_execute.

    Emits completion summary and error warnings when turbo_execute completes.

    Args:
        tool_name: Name of the tool that was called
        tool_args: Arguments passed to the tool
        result: Result returned by the tool (dict with status, counts, etc.)
        duration_ms: Duration of the tool call in milliseconds
        context: Optional context object
    """
    # Ignore non-turbo_execute tool calls
    if tool_name != "turbo_execute":
        return

    try:
        # Handle result as dict (expected format)
        if isinstance(result, dict):
            status = result.get("status", "unknown")

            success_count = result.get("success_count", 0)
            error_count = result.get("error_count", 0)
            total_duration = result.get("total_duration_ms", duration_ms)

            # Emit completion summary
            emit_success(
                f"✅ Turbo Plan completed — {success_count} success, {error_count} errors in {total_duration:.0f}ms"
            )

            # Emit warnings for each failed operation
            if error_count > 0:
                op_results = result.get("operation_results", [])
                for op_result in op_results:
                    if op_result.get("status") == "error":
                        op_id = op_result.get("operation_id", "unknown")
                        op_type = op_result.get("type", "unknown")
                        error_msg = op_result.get("error", "Unknown error")
                        emit_warning(f"   ❌ {op_type} ({op_id}): {error_msg}")

            # If overall status indicates failure but no individual errors recorded
            if status == "failed" and error_count == 0:
                emit_warning(
                    "   ❌ Turbo Plan failed with no specific operation errors"
                )

        else:
            # Unexpected result format - emit basic completion
            emit_success(f"✅ Turbo Plan completed in {duration_ms:.0f}ms")

    except Exception as e:
        logger.warning(f"Error in turbo_execute post_tool_call notification: {e}")
        # Fail silently - don't break the actual tool execution


def _format_progress_line(
    current: int, total: int, op_type: str, args: dict, is_start: bool = True
) -> str:
    """Format a progress line for an operation.

    Args:
        current: Current operation number (1-indexed)
        total: Total number of operations
        op_type: Type of operation (list_files, grep, read_files)
        args: Operation arguments dict
        is_start: True for start line, False for completion

    Returns:
        Formatted progress line string
    """
    emoji = _get_op_emoji(op_type)
    brief = _format_brief_args(op_type, args)

    if is_start:
        return f"⚡ [{current}/{total}] {emoji} {op_type} {brief} ..."
    return f"⚡ [{current}/{total}] {emoji} {op_type} {brief}"


def emit_operation_start(current: int, total: int, op_type: str, args: dict) -> None:
    """Emit operation start progress line.

    This is called from the orchestrator before each operation begins.

    Args:
        current: Current operation number (1-indexed)
        total: Total number of operations
        op_type: Type of operation
        args: Operation arguments
    """
    line = _format_progress_line(current, total, op_type, args, is_start=True)
    emit_info(line)


def emit_operation_complete(
    current: int, total: int, op_type: str, args: dict, duration_ms: float, data: dict
) -> None:
    """Emit operation completion progress line.

    This is called from the orchestrator after each operation completes.

    Args:
        current: Current operation number (1-indexed)
        total: Total number of operations
        op_type: Type of operation
        args: Operation arguments
        duration_ms: Duration in milliseconds
        data: Result data from the operation
    """
    stats = _format_brief_stats(op_type, data)
    emit_info(
        f"⚡ [{current}/{total}] ✅ {op_type} done ({duration_ms:.0f}ms, {stats})"
    )


def emit_operation_error(current: int, total: int, op_type: str, error: str) -> None:
    """Emit operation error progress line.

    This is called from the orchestrator when an operation fails.

    Args:
        current: Current operation number (1-indexed)
        total: Total number of operations
        op_type: Type of operation
        error: Error message
    """
    emit_info(f"⚡ [{current}/{total}] ❌ {op_type} failed: {error}")


def register() -> None:
    """Register turbo_execute notification callbacks.

    Call this function from the plugin's register_callbacks.py to enable
    visual notifications for turbo_execute tool calls.
    """
    register_callback("pre_tool_call", _on_pre_tool_call)
    register_callback("post_tool_call", _on_post_tool_call)
    logger.debug("Turbo Executor notification callbacks registered")
