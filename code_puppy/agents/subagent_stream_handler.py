"""Silenced event stream handler for sub-agents.

This handler suppresses all console output but still:
- Updates SubAgentConsoleManager with status/metrics
- Fires stream_event callbacks for the frontend emitter plugin
- Tracks tool calls, tokens, and status changes

Usage:
    >>> from code_puppy.agents.subagent_stream_handler import subagent_stream_handler
    >>> # In agent run:
    >>> await subagent_stream_handler(ctx, events, session_id="my-session-123")
"""

import asyncio
import logging
from collections.abc import AsyncIterable
from typing import Any

from pydantic_ai import PartDeltaEvent, PartEndEvent, PartStartEvent, RunContext
from pydantic_ai.messages import (
    TextPart,
    TextPartDelta,
    ThinkingPart,
    ThinkingPartDelta,
    ToolCallPart,
    ToolCallPartDelta,
)

from code_puppy.agents.stream_event_normalizer import normalize_stream_event
from code_puppy.token_utils import estimate_token_count as _estimate_token_count

logger = logging.getLogger(__name__)


# =============================================================================
# Callback Helper
# =============================================================================


def _fire_callback(event_type: str, event_data: Any, session_id: str | None) -> None:
    """Fire stream_event callback non-blocking.

    Schedules the callback to run asynchronously without waiting for it.
    Events are normalized to a unified schema for consistent processing by
    downstream consumers like Agent Trace.

    Silently ignores errors if no event loop is running or if the callback
    system is unavailable.

    Args:
        event_type: Type of the event ('part_start', 'part_delta', 'part_end')
        event_data: Dictionary containing event-specific data
        session_id: Optional session ID for the sub-agent
    """
    try:
        from code_puppy import callbacks

        # Normalize event data to unified schema for consistent processing
        # by downstream consumers like Agent Trace
        if isinstance(event_data, dict):
            normalized_data = normalize_stream_event(event_type, event_data)
        else:
            # Fallback for non-dict event data (shouldn't happen in practice)
            normalized_data = {
                "content_delta": str(event_data) if event_data else None,
                "args_delta": None,
                "tool_name": None,
                "tool_name_delta": None,
                "part_kind": "unknown",
                "index": -1,
                "raw": {"_original": event_data},
            }

        loop = asyncio.get_running_loop()
        loop.create_task(
            callbacks.on_stream_event(event_type, normalized_data, session_id)
        )
    except RuntimeError:
        # No event loop running - this can happen during shutdown
        logger.debug("No event loop available for stream event callback")
    except ImportError:
        # Callbacks module not available
        logger.debug("Callbacks module not available for stream event")
    except Exception as e:
        # Don't let callback errors break the stream handler
        logger.debug(f"Error firing stream event callback: {e}")


# =============================================================================
# Token Estimation
# =============================================================================


def _estimate_tokens(content: str) -> int:
    """Estimate token count from content string.

    Delegates to the shared token_utils heuristic (1 token per 2.5 chars)
    so all parts of the codebase use the same formula.

    Args:
        content: The text content to estimate tokens for

    Returns:
        Estimated token count (0 for empty content, minimum 1 otherwise)
    """
    if not content:
        return 0
    return _estimate_token_count(content)


# =============================================================================
# Main Handler
# =============================================================================


async def subagent_stream_handler(
    ctx: RunContext, events: AsyncIterable[Any], session_id: str | None = None
) -> None:
    """Silent event stream handler for sub-agents.

    Processes streaming events without producing any console output.
    Updates the SubAgentConsoleManager with status and metrics, and fires
    stream_event callbacks for any registered listeners.

    Args:
        ctx: The pydantic-ai run context
        events: Async iterable of streaming events (PartStartEvent,
                PartDeltaEvent, PartEndEvent)
        session_id: Session ID of the sub-agent for console manager updates.
                   If None, falls back to get_session_context().
    """
    # Late import to avoid circular dependencies
    from code_puppy.messaging import get_session_context
    from code_puppy.messaging.subagent_console import SubAgentConsoleManager

    manager = SubAgentConsoleManager.get_instance()

    # Resolve session_id, falling back to context if not provided
    effective_session_id = session_id or get_session_context()

    # Metrics tracking
    token_count = 0
    tool_call_count = 0
    active_tool_parts: set[int] = set()  # Track active tool call indices

    async for event in events:
        try:
            # _handle_event now handles ALL token counting and manager updates
            # It returns the updated metrics so we can track state
            token_count, tool_call_count = await _handle_event(
                event=event,
                manager=manager,
                session_id=effective_session_id,
                token_count=token_count,
                tool_call_count=tool_call_count,
                active_tool_parts=active_tool_parts,
            )

        except Exception as e:
            # Log but don't crash on event handling errors
            logger.debug(f"Error handling stream event: {e}")
            continue


async def _handle_event(
    event: Any,
    manager: Any,  # SubAgentConsoleManager
    session_id: str | None,
    token_count: int,
    tool_call_count: int,
    active_tool_parts: set[int],
) -> tuple[int, int]:
    """Handle a single streaming event.

    Updates the console manager with token counts, status, and metrics.
    Handles ALL token counting internally to ensure consistency.

    Args:
        event: The streaming event to handle
        manager: SubAgentConsoleManager instance
        session_id: Session ID for updates
        token_count: Current token count
        tool_call_count: Current tool call count
        active_tool_parts: Set of active tool call indices (modified in-place)

    Returns:
        Tuple of (updated_token_count, updated_tool_call_count)
    """
    if session_id is None:
        # Can't update manager without session_id
        logger.debug("No session_id available for stream event")
        return token_count, tool_call_count

    # -------------------------------------------------------------------------
    # PartStartEvent - Track new parts, count initial content, update status
    # -------------------------------------------------------------------------
    if isinstance(event, PartStartEvent):
        part = event.part
        event_data = {
            "index": event.index,
            "part_type": type(part).__name__,
        }

        if isinstance(part, ThinkingPart):
            # Count initial content tokens for thinking parts
            initial_content = getattr(part, "content", None)
            if initial_content:
                token_count += _estimate_tokens(initial_content)
            manager.update_agent(session_id, status="thinking", token_count=token_count)
            event_data["content"] = initial_content

        elif isinstance(part, TextPart):
            # Count initial content tokens for text parts
            initial_content = getattr(part, "content", None)
            if initial_content:
                token_count += _estimate_tokens(initial_content)
            manager.update_agent(session_id, status="running", token_count=token_count)
            event_data["content"] = initial_content

        elif isinstance(part, ToolCallPart):
            # Increment tool call count for new tool calls
            tool_call_count += 1
            active_tool_parts.add(event.index)
            manager.update_agent(
                session_id,
                status="tool_calling",
                tool_call_count=tool_call_count,
                current_tool=part.tool_name,
            )
            event_data["tool_name"] = part.tool_name
            event_data["tool_call_id"] = getattr(part, "tool_call_id", None)

        _fire_callback("part_start", event_data, session_id)

    # -------------------------------------------------------------------------
    # PartDeltaEvent - Track content deltas and update token counts
    # -------------------------------------------------------------------------
    elif isinstance(event, PartDeltaEvent):
        delta = event.delta
        event_data = {
            "index": event.index,
            "delta_type": type(delta).__name__,
        }

        if isinstance(delta, TextPartDelta):
            content_delta = delta.content_delta
            if content_delta:
                token_count += _estimate_tokens(content_delta)
                manager.update_agent(session_id, token_count=token_count)
                event_data["content_delta"] = content_delta

        elif isinstance(delta, ThinkingPartDelta):
            content_delta = delta.content_delta
            if content_delta:
                token_count += _estimate_tokens(content_delta)
                manager.update_agent(session_id, token_count=token_count)
                event_data["content_delta"] = content_delta

        elif isinstance(delta, ToolCallPartDelta):
            # Count tool call argument deltas - THIS WAS THE MISSING PIECE!
            args_delta = getattr(delta, "args_delta", None)
            if args_delta:
                token_count += _estimate_tokens(args_delta)
                manager.update_agent(session_id, token_count=token_count)
            event_data["args_delta"] = args_delta
            event_data["tool_name_delta"] = getattr(delta, "tool_name_delta", None)

        _fire_callback("part_delta", event_data, session_id)

    # -------------------------------------------------------------------------
    # PartEndEvent - Track part completion and update status
    # -------------------------------------------------------------------------
    elif isinstance(event, PartEndEvent):
        event_data = {
            "index": event.index,
            "next_part_kind": getattr(event, "next_part_kind", None),
        }

        # If this was a tool call part ending, check if we should reset status
        if event.index in active_tool_parts:
            active_tool_parts.discard(event.index)
            # If no more active tool parts after removal, reset to running
            if not active_tool_parts:
                manager.update_agent(session_id, current_tool=None, status="running")

        _fire_callback("part_end", event_data, session_id)

    return token_count, tool_call_count


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    "subagent_stream_handler",
]
