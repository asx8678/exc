"""Pre-summarization optimization: truncate large tool call args and returns.

This is a cheap pass that often reclaims significant tokens without needing an
LLM call for full summarization. Targets write_file/edit_file tool calls where
the 'content' arg can be huge, and tool returns (read_file, grep, list_files)
where the return content can be very large.
"""

import dataclasses
import logging
from typing import Any, Sequence

from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelResponse,
    ToolCallPart,
    ToolReturnPart,
)

logger = logging.getLogger(__name__)

# Tool names whose args are commonly large (content, old_string, new_string)
_TARGET_TOOLS: frozenset[str] = frozenset(
    {
        "write_file",
        "edit_file",
        "replace_in_file",
        "create_file",
        "apply_patch",
    }
)

# Keys within a tool call's args that should be truncated if oversized
_TARGET_KEYS: frozenset[str] = frozenset(
    {
        "content",
        "new_content",
        "old_string",
        "new_string",
        "patch",
        "text",
    }
)

DEFAULT_MAX_ARG_LENGTH = 500  # chars
DEFAULT_TRUNCATION_TEXT = " ...(argument truncated during compaction)"

# Tool return truncation defaults
DEFAULT_MAX_RETURN_LENGTH = 5000  # chars
DEFAULT_RETURN_HEAD_CHARS = 500  # chars to keep from start
DEFAULT_RETURN_TAIL_CHARS = 200  # chars to keep from end
DEFAULT_RETURN_TRUNCATION_TEXT = "\n...(truncated during compaction)...\n"


def truncate_tool_arg(
    value: Any,
    max_length: int = DEFAULT_MAX_ARG_LENGTH,
    truncation_text: str = DEFAULT_TRUNCATION_TEXT,
) -> tuple[Any, bool]:
    """Truncate a single arg value if it's a string and too long.

    Args:
        value: The argument value to potentially truncate
        max_length: Maximum length before truncation
        truncation_text: Text to append after truncation

    Returns:
        (new_value, was_modified)
    """
    if not isinstance(value, str):
        return value, False
    if len(value) <= max_length:
        return value, False
    return value[:max_length] + truncation_text, True


def truncate_tool_call_args(
    tool_name: str,
    args: dict[str, Any],
    *,
    max_length: int = DEFAULT_MAX_ARG_LENGTH,
    truncation_text: str = DEFAULT_TRUNCATION_TEXT,
    target_tools: frozenset[str] = _TARGET_TOOLS,
    target_keys: frozenset[str] = _TARGET_KEYS,
) -> tuple[dict[str, Any], bool]:
    """Truncate target keys in a tool call's args if it's a target tool.

    Args:
        tool_name: Name of the tool being called
        args: The arguments dict for the tool call
        max_length: Maximum length before truncation
        truncation_text: Text to append after truncation
        target_tools: Set of tool names to target for truncation
        target_keys: Set of argument keys to target for truncation

    Returns:
        (new_args_dict, was_modified)
    """
    if tool_name not in target_tools:
        return args, False

    new_args: dict[str, Any] = {}
    any_modified = False
    for key, value in args.items():
        if key in target_keys:
            new_value, modified = truncate_tool_arg(value, max_length, truncation_text)
            new_args[key] = new_value
            any_modified = any_modified or modified
        else:
            new_args[key] = value
    return new_args, any_modified


def _truncate_message_tool_calls(
    msg: ModelMessage,
    max_length: int,
) -> ModelMessage:
    """Return a new message with tool call args truncated, or the original if unchanged.

    Handles pydantic-ai's ModelResponse (which contains ToolCallPart) and
    ModelRequest (which can contain ToolCallPart when being re-sent).

    Args:
        msg: The message to process
        max_length: Maximum characters per target argument

    Returns:
        New message with truncated args, or original if no changes needed
    """
    if not isinstance(msg, (ModelResponse, ModelRequest)):
        return msg

    parts = getattr(msg, "parts", None)
    if not parts:
        return msg

    new_parts = []
    any_modified = False

    for part in parts:
        if isinstance(part, ToolCallPart):
            tool_name = getattr(part, "tool_name", "")
            args = getattr(part, "args", {}) or {}

            new_args, modified = truncate_tool_call_args(
                tool_name, args, max_length=max_length
            )

            if modified:
                new_part = dataclasses.replace(part, args=new_args)
                new_parts.append(new_part)
                any_modified = True
            else:
                new_parts.append(part)
        else:
            new_parts.append(part)

    if not any_modified:
        return msg

    if isinstance(msg, ModelResponse):
        return ModelResponse(parts=new_parts)
    elif isinstance(msg, ModelRequest):
        return ModelRequest(parts=new_parts)

    return msg


def truncate_tool_return_content(
    content: Any,
    *,
    max_length: int = DEFAULT_MAX_RETURN_LENGTH,
    head_chars: int = DEFAULT_RETURN_HEAD_CHARS,
    tail_chars: int = DEFAULT_RETURN_TAIL_CHARS,
    truncation_text: str = DEFAULT_RETURN_TRUNCATION_TEXT,
) -> tuple[Any, bool]:
    """Truncate tool return content if it's a string and too long.

    Preserves the first head_chars and last tail_chars characters with a
    truncation marker in between.

    Args:
        content: The tool return content to potentially truncate
        max_length: Total length threshold before truncation kicks in
        head_chars: Characters to keep from the start
        tail_chars: Characters to keep from the end
        truncation_text: Marker text inserted at the truncation point

    Returns:
        (new_content, was_modified)
    """
    if not isinstance(content, str):
        return content, False
    if len(content) <= max_length:
        return content, False
    total_orig = len(content)
    truncated = content[:head_chars] + truncation_text + content[-tail_chars:]
    summary_header = f"[Truncated: tool return was {total_orig} chars]\n"
    return summary_header + truncated, True


def _truncate_message_tool_returns(
    msg: ModelMessage,
    max_length: int = DEFAULT_MAX_RETURN_LENGTH,
    head_chars: int = DEFAULT_RETURN_HEAD_CHARS,
    tail_chars: int = DEFAULT_RETURN_TAIL_CHARS,
) -> ModelMessage:
    """Return a new message with tool return content truncated, or the original.

    Processes ModelRequest parts containing ToolReturnPart instances.

    Args:
        msg: The message to process
        max_length: Maximum characters before truncation kicks in
        head_chars: Characters to keep from the start of the return
        tail_chars: Characters to keep from the end of the return

    Returns:
        New message with truncated returns, or original if no changes needed
    """
    if not isinstance(msg, ModelRequest):
        return msg

    parts = getattr(msg, "parts", None)
    if not parts:
        return msg

    new_parts = []
    any_modified = False

    for part in parts:
        if isinstance(part, ToolReturnPart):
            content = part.content
            new_content, modified = truncate_tool_return_content(
                content,
                max_length=max_length,
                head_chars=head_chars,
                tail_chars=tail_chars,
            )
            if modified:
                new_part = dataclasses.replace(part, content=new_content)
                new_parts.append(new_part)
                any_modified = True
            else:
                new_parts.append(part)
        else:
            new_parts.append(part)

    if not any_modified:
        return msg

    return ModelRequest(parts=new_parts)


def pretruncate_messages(
    messages: Sequence[ModelMessage],
    *,
    keep_recent: int = 10,
    max_length: int = DEFAULT_MAX_ARG_LENGTH,
    max_return_length: int = DEFAULT_MAX_RETURN_LENGTH,
    return_head_chars: int = DEFAULT_RETURN_HEAD_CHARS,
    return_tail_chars: int = DEFAULT_RETURN_TAIL_CHARS,
) -> tuple[list[ModelMessage], int]:
    """Pre-truncate tool call args AND tool returns in older messages.

    This is an OPTIONAL cheap pass to run BEFORE full summarization. It tries to
    reclaim tokens without an LLM call.

    Args:
        messages: Full message history (pydantic-ai messages)
        keep_recent: Don't touch the last N messages (they're active context)
        max_length: Max characters allowed per target arg before truncation
        max_return_length: Max characters for tool returns before truncation
        return_head_chars: Characters to keep from start of truncated returns
        return_tail_chars: Characters to keep from end of truncated returns

    Returns:
        (modified_messages, truncation_count) -- modified_messages is a new list;
        the original is not mutated.
    """
    if len(messages) <= keep_recent:
        return list(messages), 0

    if keep_recent > 0:
        older = list(messages[:-keep_recent])
        recent = list(messages[-keep_recent:])
    else:
        older = list(messages)
        recent = []

    truncation_count = 0
    modified_older: list[ModelMessage] = []

    for msg in older:
        # First pass: truncate tool call args
        new_msg = _truncate_message_tool_calls(msg, max_length)
        # Second pass: truncate tool return content
        new_msg = _truncate_message_tool_returns(
            new_msg,
            max_length=max_return_length,
            head_chars=return_head_chars,
            tail_chars=return_tail_chars,
        )
        if new_msg is not msg:
            truncation_count += 1
        modified_older.append(new_msg)

    return modified_older + recent, truncation_count
