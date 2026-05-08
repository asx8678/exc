"""Agent helpers for conversation handling and reviewer patterns.

This module provides utilities for working with pydantic-ai conversations,
especially for multi-agent scenarios where reviewer agents need to evaluate
dialogues from different perspectives.

## Role Inversion Pattern

The `invert_conversation_roles` helper implements a pattern discovered by Orion:
when you show a reviewer agent the conversation with roles swapped, it naturally
adopts a critic/evaluator stance. This is because the reviewer "sees" the user's
prompts as if they were its own outputs, and the assistant's responses as if they
were user feedback.

### Usage Example

```python
from code_puppy.utils import invert_conversation_roles
from pydantic_ai.messages import ModelRequest, ModelResponse, UserPromptPart, TextPart

# Original conversation
conversation = [
    ModelRequest(parts=[UserPromptPart(content="What's 2+2?")]),
    ModelResponse(parts=[TextPart(content="4")]),
]

# Invert for reviewer
inverted = invert_conversation_roles(conversation)

# Now the reviewer sees:
# 1. ModelResponse with TextPart(content="What's 2+2?")  # as if IT asked this
# 2. ModelRequest with UserPromptPart(content="4")        # as if user gave feedback

# Send to reviewer agent
reviewer_response = await reviewer_agent.run(
    "Review the following conversation and identify any issues:",
    message_history=inverted,
)
```

### Why This Works

By inverting roles, the reviewer:
- Treats user questions as its own prior outputs (primes self-reflection)
- Treats assistant answers as user feedback (primes evaluation)
- Naturally shifts into a "critique" stance without explicit prompting

Based on Orion's implementation in orion-multistep-analysis/src/research_agent/agents/runtime.py:274-312
"""

from collections.abc import Iterable
from datetime import datetime, timezone

from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelResponse,
    SystemPromptPart,
    TextPart,
    ToolCallPart,
    ToolReturnPart,
    UserPromptPart,
)


def invert_conversation_roles[T: ModelMessage](
    messages: Iterable[T],
    *,
    preserve_system: bool = True,
    preserve_tool_calls: bool = True,
) -> list[ModelMessage]:
    """Return a new message list with user↔assistant roles swapped.

    This is useful for reviewer agents (security-auditor, code-reviewer, qa-expert)
    that should evaluate a conversation from the "other side" — they see user prompts
    as if they were the assistant's own outputs, which naturally puts them in a
    critique/evaluation stance.

    Based on a pattern from orion-multistep-analysis (runtime.py:274-312).

    Args:
        messages: Original conversation history (pydantic-ai ModelMessage objects).
            Accepts ModelRequest (user-side) and ModelResponse (assistant-side) messages.
        preserve_system: If True, system prompts pass through unchanged (default).
            If False, system prompts are dropped from the inverted view.
        preserve_tool_calls: If True, tool calls and their returns are kept intact
            with their respective sides (they're factual; inversion would lose information).
            If False, they are stripped.

    Returns:
        A new list of ModelMessage objects with inverted roles. The original list
        is NOT mutated.

        Mapping:
        - ModelRequest (user input) → ModelResponse (as if assistant "said" it)
        - ModelResponse (assistant output) → ModelRequest (as if user "said" it)
        - UserPromptPart content → TextPart content
        - TextPart content → UserPromptPart content
        - SystemPromptPart → passes through (if preserve_system) or dropped
        - ToolCallPart/ToolReturnPart → kept with original side (if preserve_tool_calls)

    Example:
        >>> from pydantic_ai.messages import (
        ...     ModelRequest, ModelResponse, UserPromptPart, TextPart
        ... )
        >>> original = [
        ...     ModelRequest(parts=[UserPromptPart(content="What's 2+2?")]),
        ...     ModelResponse(parts=[TextPart(content="4")]),
        ... ]
        >>> inverted = invert_conversation_roles(original)
        >>> # inverted now has:
        >>> # ModelResponse with TextPart(content="What's 2+2?")
        >>> # ModelRequest with UserPromptPart(content="4")
        >>> # A reviewer agent consuming this will treat "What's 2+2?" as its own
        >>> # output and critique the "4" answer as user feedback.
    """
    result: list[ModelMessage] = []
    now = datetime.now(tz=timezone.utc)

    for msg in messages:
        if isinstance(msg, ModelRequest):
            # User-side message → becomes assistant-side (ModelResponse)
            inverted_parts = _invert_request_parts(
                msg.parts, preserve_system, preserve_tool_calls
            )
            if inverted_parts:
                result.append(
                    ModelResponse(
                        parts=inverted_parts,
                        timestamp=now,
                    )
                )

        elif isinstance(msg, ModelResponse):
            # Assistant-side message → becomes user-side (ModelRequest)
            inverted_parts = _invert_response_parts(
                msg.parts, preserve_system, preserve_tool_calls
            )
            if inverted_parts:
                result.append(
                    ModelRequest(
                        parts=inverted_parts,
                        timestamp=now,
                    )
                )

    return result


def _invert_request_parts(
    parts: list,
    preserve_system: bool,
    preserve_tool_calls: bool,
) -> list:
    """Invert parts from a ModelRequest (user-side) for a ModelResponse.

    Mapping:
    - UserPromptPart → TextPart (content moves to "assistant said this")
    - SystemPromptPart → TextPart (if preserve_system) or dropped
    - ToolReturnPart → dropped (unless preserve_tool_calls, then kept)
    """
    result: list = []

    for part in parts:
        if isinstance(part, UserPromptPart):
            # User content → becomes assistant text
            result.append(
                TextPart(
                    content=part.content,
                )
            )

        elif isinstance(part, SystemPromptPart):
            if preserve_system:
                # System content → becomes assistant text (or could pass through as system)
                # For inversion, we convert to TextPart so it appears as assistant output
                result.append(
                    TextPart(
                        content=f"[System: {part.content}]",
                    )
                )

        elif isinstance(part, ToolReturnPart):
            if preserve_tool_calls:
                # Keep tool return with the assistant side (as text representation)
                result.append(
                    TextPart(
                        content=f"[Tool {part.tool_name} returned: {part.content}]",
                    )
                )

    return result


def _invert_response_parts(
    parts: list,
    preserve_system: bool,  # noqa: ARG001
    preserve_tool_calls: bool,
) -> list:
    """Invert parts from a ModelResponse (assistant-side) for a ModelRequest.

    Mapping:
    - TextPart → UserPromptPart (content moves to "user said this")
    - ToolCallPart → dropped (unless preserve_tool_calls, then converted to text)
    """
    result: list = []

    for part in parts:
        if isinstance(part, TextPart):
            # Assistant text → becomes user prompt
            result.append(
                UserPromptPart(
                    content=part.content,
                )
            )

        elif isinstance(part, ToolCallPart):
            if preserve_tool_calls:
                # Keep tool call info as user prompt text
                args_str = str(part.args) if part.args else "()"
                result.append(
                    UserPromptPart(
                        content=f"[Called tool {part.tool_name} with args: {args_str}]",
                    )
                )

    return result
