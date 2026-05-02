"""Stream Event Normalizer — Unified schema for streaming events.

This module provides a normalizer function that converts different stream event
formats into a unified schema, making it easier for consumers like Agent Trace
to process streaming content consistently.

Problem:
- Main agent stream (event_stream_handler.py) sends {delta_type: ..., delta: ...}
- Subagent stream (subagent_stream_handler.py) sends {content_delta, args_delta}
- Agent Trace plugin expects {content} or {text} which neither provides

Solution:
Unified schema with normalized fields:
{
    "content_delta": str | None,      # Text/thinking content delta
    "args_delta": str | None,         # Tool args delta
    "tool_name": str | None,          # Current tool name
    "tool_name_delta": str | None,    # Tool name delta (streaming)
    "part_kind": str,                 # "text", "thinking", "tool_call", etc.
    "index": int,                     # Part index
    "raw": dict                       # Original event for debugging
}
"""

from __future__ import annotations

from typing import Any


def normalize_stream_event(
    event_type: str,
    event_data: dict[str, Any],
) -> dict[str, Any]:
    """Normalize a stream event to the unified schema.

    Args:
        event_type: Type of event ('part_start', 'part_delta', 'part_end')
        event_data: Raw event data from the stream handler

    Returns:
        Normalized event dictionary following the unified schema
    """
    # Start with defaults
    normalized: dict[str, Any] = {
        "content_delta": None,
        "args_delta": None,
        "tool_name": None,
        "tool_name_delta": None,
        "part_kind": "unknown",
        "index": event_data.get("index", -1),
        "raw": event_data.copy(),
    }

    if event_type == "part_start":
        normalized["part_kind"] = _extract_part_kind_from_start(event_data)
        normalized["tool_name"] = event_data.get("tool_name")
        # For text/thinking parts, initial content might be in 'content' field
        normalized["content_delta"] = event_data.get("content")

    elif event_type == "part_delta":
        delta_type = event_data.get("delta_type", "")
        normalized["part_kind"] = _map_delta_type_to_part_kind(delta_type)

        # Handle different source formats
        if "content_delta" in event_data:
            # Subagent format: direct content_delta field
            normalized["content_delta"] = event_data["content_delta"]
        elif "args_delta" in event_data:
            # Subagent format: direct args_delta field
            normalized["args_delta"] = event_data["args_delta"]
            normalized["tool_name_delta"] = event_data.get("tool_name_delta")
        elif "delta" in event_data:
            # Main agent format: delta object with attributes
            delta = event_data["delta"]
            normalized["content_delta"] = getattr(delta, "content_delta", None)
            normalized["args_delta"] = getattr(delta, "args_delta", None)
            normalized["tool_name_delta"] = getattr(delta, "tool_name_delta", None)

        # Extract tool name from various sources
        normalized["tool_name"] = _extract_tool_name(event_data)

    elif event_type == "part_end":
        normalized["part_kind"] = _extract_part_kind_from_end(event_data)
        normalized["tool_name"] = event_data.get("tool_name")

    return normalized


def _extract_part_kind_from_start(event_data: dict[str, Any]) -> str:
    """Extract part kind from part_start event data."""
    part_type = event_data.get("part_type", "")
    kind_map = {
        "TextPart": "text",
        "ThinkingPart": "thinking",
        "ToolCallPart": "tool_call",
    }
    return kind_map.get(part_type, "unknown")


def _map_delta_type_to_part_kind(delta_type: str) -> str:
    """Map delta type string to part kind."""
    kind_map = {
        "TextPartDelta": "text",
        "ThinkingPartDelta": "thinking",
        "ToolCallPartDelta": "tool_call",
    }
    return kind_map.get(delta_type, "unknown")


def _extract_part_kind_from_end(event_data: dict[str, Any]) -> str:
    """Extract part kind from part_end event data."""
    next_part_kind = event_data.get("next_part_kind")
    if next_part_kind:
        return str(next_part_kind)
    return "unknown"


def _extract_tool_name(event_data: dict[str, Any]) -> str | None:
    """Extract tool name from event data if present."""
    # Direct field
    if "tool_name" in event_data:
        return event_data["tool_name"]
    # From delta object
    delta = event_data.get("delta")
    if delta:
        tool_name = getattr(delta, "tool_name", None)
        if tool_name:
            return tool_name
    return None


def get_stream_content_for_token_estimation(event_data: dict[str, Any]) -> str:
    """Extract content suitable for token estimation from normalized event.

    This helper makes it easy for consumers like Agent Trace to get
    the actual text content for token counting, regardless of event type.

    Args:
        event_data: Normalized event data from normalize_stream_event()

    Returns:
        String content to estimate tokens for (empty string if none)
    """
    parts: list[str] = []

    if event_data.get("content_delta"):
        parts.append(str(event_data["content_delta"]))

    if event_data.get("args_delta"):
        parts.append(str(event_data["args_delta"]))

    if event_data.get("tool_name_delta"):
        parts.append(str(event_data["tool_name_delta"]))

    return "".join(parts)
