"""Smart result summarization for turbo executor output.

Converts raw PlanResult data into human-readable markdown summaries:
- Truncates large file contents with a preview and file count
- Counts and organizes grep matches by file
- Summarizes list_files with file counts and directory structure
"""

from collections.abc import Callable
from typing import Any

from code_puppy.plugins.turbo_executor.models import (
    OperationResult,
    OperationType,
    PlanResult,
    PlanStatus,
)

# Default limits for content truncation
DEFAULT_MAX_CONTENT_LENGTH = 8000  # characters
DEFAULT_MAX_CONTENT_LINES = 100  # lines
DEFAULT_MAX_GREP_MATCHES = 50  # matches to show before summarizing


def _truncate_content(
    content: str,
    max_length: int = DEFAULT_MAX_CONTENT_LENGTH,
    max_lines: int = DEFAULT_MAX_CONTENT_LINES,
) -> str:
    """Truncate content to reasonable limits for LLM consumption.

    Args:
        content: The content to truncate
        max_length: Maximum character length
        max_lines: Maximum number of lines

    Returns:
        Truncated content with indicator if truncation occurred
    """
    if not content:
        return ""

    lines = content.split("\n")
    truncated = False

    # Truncate by lines first
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        truncated = True

    # Then truncate by character length
    result = "\n".join(lines)
    if len(result) > max_length:
        result = result[:max_length]
        truncated = True
        # Try to end at a newline or word boundary
        last_newline = result.rfind("\n")
        if last_newline > max_length * 0.8:
            result = result[:last_newline]

    if truncated:
        result += "\n\n[... content truncated ...]"

    return result


def _normalize_list_files_content(data: dict[str, Any]) -> tuple[list[str], str, bool]:
    """Normalize list_files content into a list of entries and a display string.

    Handles the various shapes that data["content"] can take at runtime:
    - str: legacy text-based listing (split on newlines)
    - list[str]: structured list of file paths (current orchestrator output)
    - dict with "files" key: wrapped dict payloads
    - None / empty / unexpected: treated as empty

    Args:
        data: The operation result data dict

    Returns:
        Tuple of (entries_list, display_text, known_shape) where display_text
        is suitable for preview/truncation and known_shape is True when the
        payload matches a recognized structure (list, str, or {"files": [...]}).
    """
    content = data.get("content")

    # None or empty → nothing to summarize
    if not content:
        return [], "", True

    # Structured list of file paths (current orchestrator output)
    if isinstance(content, list):
        entries = [str(item) for item in content if item is not None]
        display = "\n".join(entries)
        return entries, display, True

    # Wrapped dict payloads like {"files": [...]}
    if isinstance(content, dict):
        if "files" in content and isinstance(content["files"], list):
            entries = [str(f) for f in content["files"] if f is not None]
            display = "\n".join(entries)
            return entries, display, True
        # Unknown dict shape; best-effort serialization
        display = str(content)
        return [display], display, False

    # Legacy string content
    if isinstance(content, str):
        lines = [line for line in content.split("\n") if line.strip()]
        return lines, content, True

    # Fallback: stringify whatever we got
    display = str(content)
    return [display], display, False


def _summarize_list_files(data: dict[str, Any]) -> str:
    """Summarize list_files operation result.

    Handles all content shapes returned by the runtime:
    string listings, structured file lists, wrapped dicts, and empty/malformed data.

    Args:
        data: The operation result data

    Returns:
        Markdown summary string
    """
    if data.get("error"):
        return f"⚠️ **Error:** {data['error']}"

    entries, display_text, known_shape = _normalize_list_files_content(data)

    if not entries:
        return "📂 *Directory is empty or no files found*"

    # Provide a preview of the listing
    preview = _truncate_content(display_text, max_length=3000, max_lines=30)

    summary_parts = ["📂 **Directory Listing**"]

    if not known_shape:
        # Unrecognized payload - do not claim false file counts
        summary_parts.append("*unrecognized list_files payload*")
    else:
        # Count files and directories from the entries
        file_count = 0
        dir_count = 0

        for entry in entries:
            if "(type=file)" in entry or "(type=" not in entry and "." in entry:
                file_count += 1
            elif "(type=directory)" in entry:
                dir_count += 1

        if file_count == 0 and dir_count == 0 and entries:
            file_count = len(entries)

        if file_count or dir_count:
            summary_parts.append(f"*Found {file_count} files, {dir_count} directories*")

    summary_parts.append("")
    summary_parts.append("```")
    summary_parts.append(preview)
    summary_parts.append("```")

    return "\n".join(summary_parts)


def _summarize_grep(data: dict[str, Any]) -> str:
    """Summarize grep operation result.

    Args:
        data: The operation result data

    Returns:
        Markdown summary string
    """
    if data.get("error"):
        return f"⚠️ **Error:** {data['error']}"

    matches = data.get("matches", [])
    total_matches = data.get("total_matches", len(matches))

    if not matches:
        return "🔍 *No matches found*"

    # Group matches by file
    matches_by_file: dict[str, list[dict]] = {}
    for match in matches:
        file_path = match.get("file_path", "unknown")
        if file_path not in matches_by_file:
            matches_by_file[file_path] = []
        matches_by_file[file_path].append(match)

    summary_parts = [
        f"🔍 **Search Results** ({total_matches} matches in {len(matches_by_file)} files)"
    ]
    summary_parts.append("")

    # Show matches (limited)
    matches_shown = 0
    for file_path, file_matches in matches_by_file.items():
        if matches_shown >= DEFAULT_MAX_GREP_MATCHES:
            remaining_files = len(matches_by_file) - list(matches_by_file.keys()).index(
                file_path
            )
            remaining_matches = total_matches - matches_shown
            summary_parts.append(
                f"\n*... and {remaining_matches} more matches in {remaining_files} files*"
            )
            break

        summary_parts.append(f"**{file_path}** ({len(file_matches)} matches)")

        for match in file_matches:
            if matches_shown >= DEFAULT_MAX_GREP_MATCHES:
                break

            line_num = match.get("line_number", 0)
            line_content = match.get("line_content", "")
            # Truncate very long lines
            if len(line_content) > 200:
                line_content = line_content[:200] + "..."
            summary_parts.append(f"  Line {line_num}: `{line_content}`")
            matches_shown += 1

        summary_parts.append("")

    return "\n".join(summary_parts)


def _summarize_read_files(data: dict[str, Any]) -> str:
    """Summarize read_files operation result.

    Args:
        data: The operation result data

    Returns:
        Markdown summary string
    """
    files = data.get("files", [])
    total_files = data.get("total_files", len(files))
    successful = data.get("successful_reads", sum(1 for f in files if f.get("success")))

    summary_parts = [
        f"📄 **File Contents** ({successful}/{total_files} files read successfully)"
    ]
    summary_parts.append("")

    for file_info in files:
        file_path = file_info.get("file_path", "unknown")
        content = file_info.get("content", "")
        error = file_info.get("error")
        success = file_info.get("success", False)

        if not success:
            summary_parts.append(f"❌ **{file_path}** - Error: {error}")
            summary_parts.append("")
            continue

        if content is None:
            summary_parts.append(f"⚠️ **{file_path}** - No content")
            summary_parts.append("")
            continue

        # Truncate content
        truncated = _truncate_content(content)
        token_count = file_info.get("num_tokens", 0)

        summary_parts.append(f"**{file_path}**")
        if token_count:
            summary_parts.append(f"*{token_count} tokens*")
        summary_parts.append("```")
        summary_parts.append(truncated)
        summary_parts.append("```")
        summary_parts.append("")

    return "\n".join(summary_parts)


# Mapping of operation types to their summarizers
_OPERATION_SUMMARIZERS: dict[OperationType, Callable] = {
    OperationType.LIST_FILES: _summarize_list_files,
    OperationType.GREP: _summarize_grep,
    OperationType.READ_FILES: _summarize_read_files,
}


def summarize_operation_result(result: OperationResult) -> str:
    """Generate a human-readable summary for a single operation result.

    If the per-type summarizer raises, returns a neutral fallback instead
    of propagating the exception so that plan-level summaries remain intact.

    Args:
        result: The operation result to summarize

    Returns:
        Markdown-formatted summary string
    """
    if result.status == "error":
        return f"❌ **Operation Failed:** {result.error}"

    summarizer = _OPERATION_SUMMARIZERS.get(result.type)
    if not summarizer:
        return f"📋 **{result.type.value}** (no summary available)"

    try:
        return summarizer(result.data)
    except Exception:
        return (
            f"⚠️ **{result.type.value}** — summary unavailable "
            f"(structured data returned successfully)"
        )


def summarize_plan_result(
    plan_result: PlanResult,
    include_operation_details: bool = True,
) -> str:
    """Generate a comprehensive markdown summary of a plan execution result.

    Args:
        plan_result: The plan result to summarize
        include_operation_details: Whether to include detailed operation summaries

    Returns:
        Markdown-formatted summary string
    """
    # Status emoji mapping
    status_emojis = {
        PlanStatus.COMPLETED: "✅",
        PlanStatus.PARTIAL: "⚠️",
        PlanStatus.FAILED: "❌",
        PlanStatus.RUNNING: "⏳",
        PlanStatus.PENDING: "⏸️",
    }

    emoji = status_emojis.get(plan_result.status, "📋")

    # Build header
    lines = [
        f"{emoji} **Plan Execution: {plan_result.plan_id}**",
        "",
        f"**Status:** {plan_result.status.value}",
        f"**Operations:** {plan_result.success_count} success, {plan_result.error_count} errors",
        f"**Duration:** {plan_result.total_duration_ms:.1f}ms",
    ]

    if plan_result.metadata:
        total_ops = plan_result.metadata.get("total_operations", 0)
        if total_ops:
            lines.append(f"**Total Operations:** {total_ops}")

    lines.append("")

    # Add operation summaries
    if include_operation_details and plan_result.operation_results:
        lines.append("---")
        lines.append("")
        lines.append("### Operation Results")
        lines.append("")

        for i, op_result in enumerate(plan_result.operation_results, 1):
            lines.append(f"#### {i}. {op_result.type.value}")
            if op_result.operation_id:
                lines.append(f"*ID: {op_result.operation_id}*")
            lines.append("")
            lines.append(summarize_operation_result(op_result))
            lines.append("")

    # Add error summary if there are errors
    if plan_result.error_count > 0:
        lines.append("---")
        lines.append("")
        lines.append("### Errors")
        lines.append("")

        for op_result in plan_result.get_errors():
            lines.append(
                f"- **{op_result.type.value}** (`{op_result.operation_id}`): {op_result.error}"
            )

    return "\n".join(lines)


def quick_summary(plan_result: PlanResult) -> str:
    """Generate a one-line summary of plan execution.

    Args:
        plan_result: The plan result to summarize

    Returns:
        Short summary string
    """
    status_emoji = {
        PlanStatus.COMPLETED: "✅",
        PlanStatus.PARTIAL: "⚠️",
        PlanStatus.FAILED: "❌",
    }.get(plan_result.status, "📋")

    return (
        f"{status_emoji} Plan '{plan_result.plan_id}': "
        f"{plan_result.success_count}/{plan_result.success_count + plan_result.error_count} ops, "
        f"{plan_result.total_duration_ms:.0f}ms"
    )
