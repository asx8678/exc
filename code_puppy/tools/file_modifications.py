"""Robust, always-diff-logging file-modification helpers + agent tools.

Key guarantees
--------------
1. **A diff is printed _inline_ on every path** (success, no-op, or error) – no decorator magic.
2. **Full traceback logging** for unexpected errors via `_log_error`.
3. Helper functions stay print-free and return a `diff` key, while agent-tool wrappers handle
   all console output.
4. **Async-first API** – all public functions are async and run blocking I/O in thread pools.
"""

import asyncio
import difflib
import json
import os
import re
import traceback
import warnings
from typing import Annotated, Any

import json_repair
from pydantic import BaseModel, WithJsonSchema
from pydantic_ai import RunContext

from code_puppy.callbacks import on_delete_file, on_edit_file
from code_puppy.config import get_diff_context_lines, get_post_edit_validation_enabled
from code_puppy.messaging import (  # Structured messaging types
    DiffLine,
    DiffMessage,
    emit_error,
    emit_warning,
    get_message_bus,
)
from code_puppy.tools.common import _find_best_window, generate_group_id
from code_puppy.utils.eol import restore_bom, strip_bom
from code_puppy.utils.file_display import safe_write_file
from code_puppy.utils.file_mutex import file_lock
from code_puppy.utils.whitespace import strip_added_blank_lines

# Threshold for fuzzy matching
_FUZZY_THRESHOLD = 0.95

# Syntax validation imports
# Deferred to function level to fail-open if imports break
try:
    from code_puppy.utils.syntax_validate import (
        format_validation_errors_for_agent,
        validate_file_sync,
    )

    _SYNTAX_VALIDATE_AVAILABLE = True
except Exception:
    _SYNTAX_VALIDATE_AVAILABLE = False

# Hoisted import for file_permission_handler with optional dependency guard
try:
    from code_puppy.plugins.file_permission_handler.register_callbacks import (
        clear_user_feedback,
        get_last_user_feedback,
    )

    _FILE_PERMISSION_HANDLER_AVAILABLE = True
except ImportError:
    _FILE_PERMISSION_HANDLER_AVAILABLE = False

# Pre-compiled regex for parsing git diff hunk headers
# Format: @@ -start,count +start,count @@
_HUNK_HEADER_RE = re.compile(r"@@ -\d+(?:,\d+)? \+(\d+)")


def _create_rejection_response(file_path: str) -> dict[str, Any]:
    """Create a standardized rejection response with user feedback if available.

    Args:
        file_path: Path to the file that was rejected

    Returns:
        Dict containing rejection details and any user feedback
    """
    # Check for user feedback from permission handler
    user_feedback = None
    if _FILE_PERMISSION_HANDLER_AVAILABLE:
        user_feedback = get_last_user_feedback()
        # Clear feedback after reading it
        clear_user_feedback()

    rejection_message = (
        "USER REJECTED: The user explicitly rejected these file changes."
    )
    if user_feedback:
        rejection_message += f" User feedback: {user_feedback}"
    else:
        rejection_message += " Please do not retry the same changes or any other changes - immediately ask for clarification."

    return {
        "success": False,
        "path": file_path,
        "message": rejection_message,
        "changed": False,
        "user_rejection": True,
        "rejection_type": "explicit_user_denial",
        "user_feedback": user_feedback,
    }


def _maybe_attach_syntax_warning(result: dict[str, Any], file_path: str) -> None:
    """Attach syntax warning to result dict if validation detects issues.

    This function mutates the result dict in-place to add a 'syntax_warning'
    key if post-edit validation finds syntax errors. The edit operation itself
    is NOT blocked - this is purely advisory for the agent to self-correct.

    Args:
        result: The result dict from a successful file operation
        file_path: Path to the file that was just written
    """
    # Only validate successful operations on validatable extensions
    if not result.get("success"):
        return
    if not get_post_edit_validation_enabled():
        return
    if not _SYNTAX_VALIDATE_AVAILABLE:
        return

    try:
        # Read the final content from disk (ensures we validate what was written)
        with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            final_content = f.read()

        # Run validation with 500ms timeout
        v_result = validate_file_sync(file_path, final_content, timeout_s=0.5)
        warning = format_validation_errors_for_agent(v_result)
        if warning:
            result["syntax_warning"] = warning
    except Exception as e:
        # Never let validation failures break the edit operation
        # This ensures the fail-open guarantee
        import logging

        logging.getLogger(__name__).debug(
            "post-edit validation skipped for %s: %s", file_path, e
        )


class DeleteSnippetPayload(BaseModel):
    file_path: str
    delete_snippet: str


class Replacement(BaseModel):
    old_str: str
    new_str: str


class ReplacementsPayload(BaseModel):
    file_path: str
    replacements: list[Replacement]


class ContentPayload(BaseModel):
    file_path: str
    content: str
    overwrite: bool = False


EditFilePayload = DeleteSnippetPayload | ReplacementsPayload | ContentPayload


def _parse_diff_lines(diff_text: str) -> list[DiffLine]:
    """Parse unified diff text into structured DiffLine objects.

    Args:
        diff_text: Raw unified diff text

    Returns:
        List of DiffLine objects with line numbers and types
    """
    if not diff_text or not diff_text.strip():
        return []

    diff_lines = []
    line_number = 0

    for line in diff_text.splitlines():
        # Determine line type based on diff markers
        if line.startswith("+") and not line.startswith("+++"):
            line_type = "add"
            line_number += 1
            content = line[1:]  # Remove the + prefix
        elif line.startswith("-") and not line.startswith("---"):
            line_type = "remove"
            line_number += 1
            content = line[1:]  # Remove the - prefix
        elif line.startswith("@@"):
            # Parse hunk header to get line number
            match = _HUNK_HEADER_RE.search(line)
            if match:
                line_number = (
                    int(match.group(1)) - 1
                )  # Will be incremented on next line
            line_type = "context"
            content = line
        elif line.startswith("---") or line.startswith("+++"):
            # File headers - treat as context
            line_type = "context"
            content = line
        else:
            line_type = "context"
            line_number += 1
            content = line

        diff_lines.append(
            DiffLine(line_number=max(1, line_number), type=line_type, content=content)
        )

    return diff_lines


def _emit_diff_message(
    file_path: str,
    operation: str,
    diff_text: str,
    old_content: str | None = None,
    new_content: str | None = None,
) -> None:
    """Emit a structured DiffMessage for UI display.

    Args:
        file_path: Path to the file being modified
        operation: One of 'create', 'modify', 'delete'
        diff_text: Raw unified diff text
        old_content: Original file content (optional)
        new_content: New file content (optional)
    """
    # Check if diff was already shown during permission prompt
    try:
        from code_puppy.plugins.file_permission_handler.register_callbacks import (
            clear_diff_shown_flag,
            was_diff_already_shown,
        )

        if was_diff_already_shown():
            # Diff already displayed in permission panel, skip redundant display
            clear_diff_shown_flag()
            return
    except ImportError:
        pass  # Permission handler not available, emit anyway

    if not diff_text or not diff_text.strip():
        return

    diff_lines = _parse_diff_lines(diff_text)

    diff_msg = DiffMessage(
        path=file_path,
        operation=operation,
        old_content=old_content,
        new_content=new_content,
        diff_lines=diff_lines,
        raw_diff_text=diff_text,
    )
    get_message_bus().emit(diff_msg)


def _log_error(
    msg: str, exc: Exception | None = None, message_group: str | None = None
) -> None:
    emit_error(f"{msg}", message_group=message_group)
    if exc is not None:
        emit_error(traceback.format_exc(), highlight=False, message_group=message_group)


def _sanitize_surrogates(text: str) -> str:
    """Sanitize surrogate characters from text read with surrogateescape.

    Args:
        text: Text potentially containing surrogate characters

    Returns:
        Text with surrogates replaced
    """
    try:
        return text.encode("utf-8", errors="surrogatepass").decode(
            "utf-8", errors="replace"
        )
    except UnicodeEncodeError, UnicodeDecodeError:
        return text


def _delete_snippet_from_file(
    context: RunContext | None,
    file_path: str,
    snippet: str,
    message_group: str | None = None,
) -> dict[str, Any]:
    assert os.path.isabs(file_path), f"Expected absolute path, got {file_path!r}"
    diff_text = ""
    try:
        if not os.path.exists(file_path) or not os.path.isfile(file_path):
            return {"error": f"File '{file_path}' does not exist.", "diff": diff_text}
        with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            original = f.read()
        # Sanitize any surrogate characters from reading
        original = _sanitize_surrogates(original)
        # Strip BOM for matching (LLM output never has BOM)
        original, bom = strip_bom(original)
        if snippet not in original:
            return {
                "error": f"Snippet not found in file '{file_path}'.",
                "diff": diff_text,
            }
        modified = original.replace(snippet, "", 1)
        # Split once at entry point and pass lines to helper
        original_lines = original.splitlines(keepends=True)
        modified_lines = modified.splitlines(keepends=True)
        diff_text = "".join(
            difflib.unified_diff(
                original_lines,
                modified_lines,
                fromfile=f"a/{os.path.basename(file_path)}",
                tofile=f"b/{os.path.basename(file_path)}",
                n=get_diff_context_lines(),
            )
        )
        # SECURITY FIX (deepagents ADOPT #3): Use O_NOFOLLOW to prevent symlink attacks
        # Restore BOM if the original file had one
        safe_write_file(file_path, restore_bom(modified, bom), encoding="utf-8")
        return {
            "success": True,
            "path": file_path,
            "message": "Snippet deleted from file.",
            "changed": True,
            "diff": diff_text,
        }
    except Exception as exc:
        return {"error": str(exc), "diff": diff_text}


def _replace_in_file(
    context: RunContext | None,
    path: str,
    replacements: list[dict[str, str]],
    message_group: str | None = None,
) -> dict[str, Any]:
    """Robust replacement engine with explicit edge‑case reporting.

    Optimized to cache splitlines() results and avoid repeated string operations.
    Uses cached line arrays and pre-computed needle lines for fuzzy matching.
    """
    assert os.path.isabs(path), f"Expected absolute path, got {path!r}"
    file_path = path
    diff_text = ""
    try:
        if not os.path.exists(file_path) or not os.path.isfile(file_path):
            return {"error": f"File '{file_path}' does not exist.", "diff": diff_text}

        with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            original = f.read()

        # Sanitize any surrogate characters from reading
        original = _sanitize_surrogates(original)
        # Strip BOM for matching (LLM output never has BOM)
        original, bom = strip_bom(original)

        # Pure Python implementation (acceleration layer removed)
        modified = original
        modified_lines: list[str] | None = None

        for rep in replacements:
            old_str = rep.get("old_str", "")
            new_str = rep.get("new_str", "")

            # Skip empty old_str - nothing to match
            if not old_str:
                continue

            # Fast path: exact match - replace first occurrence only
            if old_str in modified:
                modified = modified.replace(old_str, new_str, 1)
                # Invalidate cached lines since content changed
                modified_lines = None
                continue

            # Lazy initialization of cached lines for fuzzy matching
            if modified_lines is None:
                modified_lines = modified.splitlines()

            # Pre-compute needle lines and length for cache
            needle_stripped = old_str.rstrip("\n")
            needle_lines = needle_stripped.splitlines()
            needle_len = len(needle_stripped)

            loc, score = _find_best_window(
                modified_lines,
                old_str,
                _needle_lines_cache=needle_lines,
                _needle_len_cache=needle_len,
            )

            if score < _FUZZY_THRESHOLD or loc is None:
                return {
                    "error": f"No suitable match in content (JW {score:.3f} < {_FUZZY_THRESHOLD})",
                    "jw_score": score,
                    "received": None,
                    "diff": "",
                }

            start, end = loc
            # Use slice-assignment to modify lines in-place, preserving cache
            new_lines = new_str.rstrip("\n").splitlines()
            modified_lines[start:end] = new_lines

            # Rebuild the string for subsequent exact matches
            modified = "\n".join(modified_lines)
            if original.endswith("\n") and not modified.endswith("\n"):
                modified += "\n"

        # Strip surplus blank lines that the LLM may have hallucinated
        modified = strip_added_blank_lines(original, modified)

        if modified == original:
            emit_warning(
                "No changes to apply – proposed content is identical.",
                message_group=message_group,
            )
            return {
                "success": False,
                "path": file_path,
                "message": "No changes to apply.",
                "changed": False,
                "diff": "",
            }

        # Split once at entry point and pass lines to helper
        original_lines = original.splitlines(keepends=True)
        modified_lines = modified.splitlines(keepends=True)
        diff_text = "".join(
            difflib.unified_diff(
                original_lines,
                modified_lines,
                fromfile=f"a/{os.path.basename(file_path)}",
                tofile=f"b/{os.path.basename(file_path)}",
                n=get_diff_context_lines(),
            )
        )
        # SECURITY FIX (deepagents ADOPT #3): Use O_NOFOLLOW to prevent symlink attacks
        # Restore BOM if the original file had one
        safe_write_file(file_path, restore_bom(modified, bom), encoding="utf-8")
        return {
            "success": True,
            "path": file_path,
            "message": "Replacements applied.",
            "changed": True,
            "diff": diff_text,
        }
    except Exception as exc:
        return {"error": str(exc), "diff": diff_text}


def _write_to_file(
    context: RunContext | None,
    path: str,
    content: str,
    overwrite: bool = False,
    message_group: str | None = None,
) -> dict[str, Any]:
    assert os.path.isabs(path), f"Expected absolute path, got {path!r}"
    file_path = path

    try:
        exists = os.path.exists(file_path)
        if exists and not overwrite:
            return {
                "success": False,
                "path": file_path,
                "message": f"Cowardly refusing to overwrite existing file: {file_path}",
                "changed": False,
                "diff": "",
            }

        if exists:
            with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
                old_content = f.read()
            old_content = _sanitize_surrogates(old_content)
            # Preserve BOM from original file for restoration
            old_content, bom = strip_bom(old_content)
            # Strip surplus blank lines that the LLM may have hallucinated
            content = strip_added_blank_lines(old_content, content)
            old_lines = old_content.splitlines(keepends=True)
        else:
            old_lines = []

        # Split once at entry point and pass lines to helper
        content_lines = content.splitlines(keepends=True)
        diff_lines = difflib.unified_diff(
            old_lines,
            content_lines,
            fromfile="/dev/null" if not exists else f"a/{os.path.basename(file_path)}",
            tofile=f"b/{os.path.basename(file_path)}",
            n=get_diff_context_lines(),
        )
        diff_text = "".join(diff_lines)

        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        # SECURITY FIX (deepagents ADOPT #3): Use O_NOFOLLOW to prevent symlink attacks
        # Restore BOM if the original file had one (new content from LLM won't have BOM)
        safe_write_file(
            file_path, restore_bom(content, bom if exists else ""), encoding="utf-8"
        )

        action = "overwritten" if exists else "created"
        return {
            "success": True,
            "path": file_path,
            "message": f"File '{file_path}' {action} successfully.",
            "changed": True,
            "diff": diff_text,
        }

    except Exception as exc:
        _log_error("Unhandled exception in write_to_file", exc)
        return {"error": str(exc), "diff": ""}


async def delete_snippet_from_file(
    context: RunContext, file_path: str, snippet: str, message_group: str | None = None
) -> dict[str, Any]:
    # Use the plugin system for permission handling with operation data
    from code_puppy.callbacks import on_file_permission_async

    operation_data = {"snippet": snippet}
    permission_results = await on_file_permission_async(
        context, file_path, "delete snippet from", None, message_group, operation_data
    )

    # If any permission handler denies the operation, return cancelled result
    if permission_results and any(
        not result for result in permission_results if result is not None
    ):
        return _create_rejection_response(file_path)

    async with file_lock(file_path):
        res = await asyncio.to_thread(
            _delete_snippet_from_file,
            context,
            file_path,
            snippet,
            message_group=message_group,
        )
    diff = res.get("diff", "")
    if diff:
        _emit_diff_message(file_path, "modify", diff)
    # Post-edit syntax validation
    _maybe_attach_syntax_warning(res, file_path)
    return res


async def write_to_file(
    context: RunContext,
    path: str,
    content: str,
    overwrite: bool,
    message_group: str | None = None,
) -> dict[str, Any]:
    # Use the plugin system for permission handling with operation data
    from code_puppy.callbacks import on_file_permission_async

    operation_data = {"content": content, "overwrite": overwrite}
    permission_results = await on_file_permission_async(
        context, path, "write", None, message_group, operation_data
    )

    # If any permission handler denies the operation, return cancelled result
    if permission_results and any(
        not result for result in permission_results if result is not None
    ):
        return _create_rejection_response(path)

    async with file_lock(path):
        res = await asyncio.to_thread(
            _write_to_file,
            context,
            path,
            content,
            overwrite=overwrite,
            message_group=message_group,
        )
    diff = res.get("diff", "")
    if diff:
        # Determine operation type based on whether file existed
        operation = "modify" if overwrite else "create"
        _emit_diff_message(path, operation, diff, new_content=content)
    # Post-edit syntax validation
    _maybe_attach_syntax_warning(res, path)
    return res


async def replace_in_file(
    context: RunContext,
    path: str,
    replacements: list[dict[str, str]],
    message_group: str | None = None,
) -> dict[str, Any]:
    # Use the plugin system for permission handling with operation data
    from code_puppy.callbacks import on_file_permission_async

    operation_data = {"replacements": replacements}
    permission_results = await on_file_permission_async(
        context, path, "replace text in", None, message_group, operation_data
    )

    # If any permission handler denies the operation, return cancelled result
    if permission_results and any(
        not result for result in permission_results if result is not None
    ):
        return _create_rejection_response(path)

    async with file_lock(path):
        res = await asyncio.to_thread(
            _replace_in_file, context, path, replacements, message_group=message_group
        )
    diff = res.get("diff", "")
    if diff:
        _emit_diff_message(path, "modify", diff)
    # Post-edit syntax validation
    _maybe_attach_syntax_warning(res, path)
    return res


async def _edit_file(
    context: RunContext, payload: EditFilePayload, group_id: str | None = None
) -> dict[str, Any]:
    """
    High-level implementation of the *edit_file* behaviour.

    This function performs the heavy-lifting after the lightweight agent-exposed wrapper has
    validated / coerced the inbound *payload* to one of the Pydantic models declared at the top
    of this module.

    Supported payload variants
    --------------------------
    • **ContentPayload** – full file write / overwrite.
    • **ReplacementsPayload** – targeted in-file replacements.
    • **DeleteSnippetPayload** – remove an exact snippet.

    The helper decides which low-level routine to delegate to and ensures the resulting unified
    diff is always returned so the caller can pretty-print it for the user.

    Parameters
    ----------
    path : str
        Path to the target file (relative or absolute)
    diff : str
        Either:
            * Raw file content (for file creation)
            * A JSON string with one of the following shapes:
                {"content": "full file contents", "overwrite": true}
                {"replacements": [ {"old_str": "foo", "new_str": "bar"}, ... ] }
                {"delete_snippet": "text to remove"}

    The function auto-detects the payload type and routes to the appropriate internal helper.
    """
    # Extract file_path from payload
    file_path = os.path.abspath(payload.file_path)

    # Use provided group_id or generate one if not provided
    if group_id is None:
        group_id = generate_group_id("edit_file", file_path)

    try:
        if isinstance(payload, DeleteSnippetPayload):
            return await delete_snippet_from_file(
                context, file_path, payload.delete_snippet, message_group=group_id
            )
        elif isinstance(payload, ReplacementsPayload):
            # Convert Pydantic Replacement models to dict format using model_dump
            # (single direct transformation instead of manual dict construction)
            replacements_dict = [rep.model_dump() for rep in payload.replacements]
            return await replace_in_file(
                context, file_path, replacements_dict, message_group=group_id
            )
        elif isinstance(payload, ContentPayload):
            file_exists = os.path.exists(file_path)
            if file_exists and not payload.overwrite:
                return {
                    "success": False,
                    "path": file_path,
                    "message": f"File '{file_path}' exists. Set 'overwrite': true to replace.",
                    "changed": False,
                }
            return await write_to_file(
                context,
                file_path,
                payload.content,
                payload.overwrite,
                message_group=group_id,
            )
        else:
            return {
                "success": False,
                "path": file_path,
                "message": f"Unknown payload type: {type(payload)}",
                "changed": False,
            }
    except Exception as e:
        emit_error(
            "Unable to route file modification tool call to sub-tool",
            message_group=group_id,
        )
        emit_error(str(e), message_group=group_id)
        return {
            "success": False,
            "path": file_path,
            "message": f"Something went wrong in file editing: {str(e)}",
            "changed": False,
        }


async def _delete_file(
    context: RunContext, file_path: str, message_group: str | None = None
) -> dict[str, Any]:
    assert os.path.isabs(file_path), f"Expected absolute path, got {file_path!r}"

    # Use the plugin system for permission handling with operation data
    from code_puppy.callbacks import on_file_permission_async

    operation_data = {}  # No additional data needed for delete operations
    permission_results = await on_file_permission_async(
        context, file_path, "delete", None, message_group, operation_data
    )

    # If any permission handler denies the operation, return cancelled result
    if permission_results and any(
        not result for result in permission_results if result is not None
    ):
        return _create_rejection_response(file_path)

    def _do_delete():
        if not os.path.exists(file_path) or not os.path.isfile(file_path):
            return {"error": f"File '{file_path}' does not exist.", "diff": ""}
        # Get file stats for summary, avoiding full read for large files
        file_size = os.path.getsize(file_path)
        # Count lines efficiently without loading entire file into memory
        line_count = 0
        with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            for _ in f:
                line_count += 1
        # Create summary diff instead of full content diff
        diff_text = (
            f"--- a/{os.path.basename(file_path)}\n+++ /dev/null\n@@ -1,{line_count} +0,0 @@\n"
            + f"< File deleted: {line_count} lines, {file_size} bytes >\n"
        )
        os.remove(file_path)
        return {
            "success": True,
            "path": file_path,
            "message": f"File '{file_path}' deleted successfully.",
            "changed": True,
            "diff": diff_text,
        }

    try:
        res = await asyncio.to_thread(_do_delete)
    except Exception as exc:
        _log_error("Unhandled exception in delete_file", exc)
        res = {"error": str(exc), "diff": ""}

    diff = res.get("diff", "")
    if diff:
        _emit_diff_message(file_path, "delete", diff)
    return res


def register_edit_file(agent):
    """Register only the edit_file tool.

    .. deprecated::
        Use register_create_file, register_replace_in_file, and
        register_delete_snippet instead. edit_file is auto-expanded
        to these three tools when listed in an agent's tool config.
    """
    warnings.warn(
        "register_edit_file() is deprecated. Use register_create_file, "
        "register_replace_in_file, and register_delete_snippet instead. "
        "Agents listing 'edit_file' in their tools config will automatically "
        "get the three new tools via TOOL_EXPANSIONS.",
        DeprecationWarning,
        stacklevel=2,
    )

    @agent.tool
    async def edit_file(
        context: RunContext, payload: EditFilePayload | str = ""
    ) -> dict[str, Any]:
        """Comprehensive file editing tool supporting multiple modification strategies.

        Supports: ContentPayload (create/overwrite), ReplacementsPayload (targeted edits),
        DeleteSnippetPayload (remove text). Prefer ReplacementsPayload for existing files.
        """
        # Handle string payload parsing (for models that send JSON strings)

        parse_error_message = "Payload must contain one of: 'content', 'replacements', or 'delete_snippet' with a 'file_path'."

        if isinstance(payload, str):
            try:
                # Fallback for weird models that just can't help but send json strings...
                payload_dict = json.loads(json_repair.repair_json(payload))
                if "replacements" in payload_dict:
                    payload = ReplacementsPayload(**payload_dict)
                elif "delete_snippet" in payload_dict:
                    payload = DeleteSnippetPayload(**payload_dict)
                elif "content" in payload_dict:
                    payload = ContentPayload(**payload_dict)
                else:
                    file_path = "Unknown"
                    if "file_path" in payload_dict:
                        file_path = payload_dict["file_path"]
                    return {
                        "success": False,
                        "path": file_path,
                        "message": parse_error_message,
                        "changed": False,
                    }
            except Exception as e:
                return {
                    "success": False,
                    "path": "Not retrievable in Payload",
                    "message": f"edit_file call failed: {str(e)} - {parse_error_message}",
                    "changed": False,
                }

        # Call _edit_file which will extract file_path from payload and handle group_id generation
        result = await _edit_file(context, payload)
        if "diff" in result:
            del result["diff"]

        # Trigger edit_file callbacks to enhance the result with rejection details
        enhanced_results = on_edit_file(context, result, payload)
        if enhanced_results:
            # Use the first non-None enhanced result
            for enhanced_result in enhanced_results:
                if enhanced_result is not None:
                    result = enhanced_result
                    break

        return result


def register_delete_file(agent):
    """Register only the delete_file tool."""

    @agent.tool
    async def delete_file(context: RunContext, file_path: str = "") -> dict[str, Any]:
        """Safely delete files with comprehensive logging and diff generation.

        Shows exactly what content was removed via diff output.
        """
        file_path = os.path.abspath(file_path)
        # Generate group_id for delete_file tool execution
        group_id = generate_group_id("delete_file", file_path)
        result = await _delete_file(context, file_path, message_group=group_id)
        if "diff" in result:
            del result["diff"]

        # Trigger delete_file callbacks to enhance the result with rejection details
        enhanced_results = on_delete_file(context, result, file_path)
        if enhanced_results:
            # Use the first non-None enhanced result
            for enhanced_result in enhanced_results:
                if enhanced_result is not None:
                    result = enhanced_result
                    break

        return result


# Module-level aliases captured before registration functions are defined.
# Inside register_replace_in_file, the @agent.tool decorator creates a local
# function named 'replace_in_file' which shadows the module-level helper of the
# same name for the entire enclosing scope (Python scoping rules). We capture
# a reference here so the registration function can call the helper.
_replace_in_file_helper = replace_in_file


def register_create_file(agent):
    """Register the create_file tool for creating or overwriting files."""
    # Local alias to avoid shadowing by the @agent.tool decorated function below
    _write_file = write_to_file

    @agent.tool
    async def create_file(
        context: RunContext,
        file_path: str = "",
        content: str = "",
        overwrite: bool = False,
    ) -> dict[str, Any]:
        """Create a new file or overwrite an existing one with the provided content."""
        file_path = os.path.abspath(file_path)
        group_id = generate_group_id("create_file", file_path)
        result = await _write_file(
            context, file_path, content, overwrite, message_group=group_id
        )
        if "diff" in result:
            del result["diff"]

        # Trigger legacy edit_file callbacks for backward compatibility
        payload = ContentPayload(
            file_path=file_path, content=content, overwrite=overwrite
        )
        enhanced_results = on_edit_file(context, result, payload)
        if enhanced_results:
            for enhanced_result in enhanced_results:
                if enhanced_result is not None:
                    result = enhanced_result
                    break

        return result


# Inline JSON schema for Replacement objects — avoids $defs/$ref that many
# LLM providers misinterpret, causing frequent validation errors and
# fallback to full-file rewrites. See _sanitize_schema_for_gemini and
# _inline_refs in the antigravity plugin for prior art.
_REPLACEMENT_ITEM_SCHEMA = {
    "type": "object",
    "properties": {
        "old_str": {"type": "string"},
        "new_str": {"type": "string"},
    },
    "required": ["old_str", "new_str"],
}

# Type alias used by the tool signature. The Annotated + WithJsonSchema
# tells Pydantic to emit _REPLACEMENT_ITEM_SCHEMA inline instead of a $ref.
InlineReplacement = Annotated[dict[str, str], WithJsonSchema(_REPLACEMENT_ITEM_SCHEMA)]


def register_replace_in_file(agent):
    """Register the replace_in_file tool for targeted text replacements."""

    @agent.tool
    async def replace_in_file(
        context: RunContext,
        file_path: str = "",
        replacements: list[InlineReplacement] | None = None,
    ) -> dict[str, Any]:
        """Apply targeted text replacements to an existing file.

        Each replacement specifies an old_str to find and a new_str to replace it with.
        Replacements are applied sequentially. Prefer this over full file rewrites.
        """
        if replacements is None:
            replacements = []
        file_path = os.path.abspath(file_path)
        group_id = generate_group_id("replace_in_file", file_path)
        # replacements arrive as plain dicts — pass them straight through
        # (no transformation needed - InlineReplacement is already dict[str, str])
        result = await _replace_in_file_helper(
            context, file_path, replacements, message_group=group_id
        )
        if "diff" in result:
            del result["diff"]

        # Trigger legacy edit_file callbacks for backward compatibility
        payload = ReplacementsPayload(
            file_path=file_path,
            replacements=[
                Replacement(old_str=r["old_str"], new_str=r["new_str"])
                for r in replacements
            ],
        )
        enhanced_results = on_edit_file(context, result, payload)
        if enhanced_results:
            for enhanced_result in enhanced_results:
                if enhanced_result is not None:
                    result = enhanced_result
                    break

        return result


def register_delete_snippet(agent):
    """Register the delete_snippet tool for removing text from files."""
    # Local alias to avoid shadowing by the @agent.tool decorated function below
    _remove_snippet = delete_snippet_from_file

    @agent.tool
    async def delete_snippet(
        context: RunContext, file_path: str = "", snippet: str = ""
    ) -> dict[str, Any]:
        """Remove the first occurrence of a text snippet from a file."""
        file_path = os.path.abspath(file_path)
        group_id = generate_group_id("delete_snippet", file_path)
        result = await _remove_snippet(
            context, file_path, snippet, message_group=group_id
        )
        if "diff" in result:
            del result["diff"]

        # Trigger legacy edit_file callbacks for backward compatibility
        payload = DeleteSnippetPayload(file_path=file_path, delete_snippet=snippet)
        enhanced_results = on_edit_file(context, result, payload)
        if enhanced_results:
            for enhanced_result in enhanced_results:
                if enhanced_result is not None:
                    result = enhanced_result
                    break

        return result
