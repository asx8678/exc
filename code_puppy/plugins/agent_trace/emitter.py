"""Agent Trace V2 — Event Emitters.

Factory functions for creating properly structured TraceEvents.
These are the primary API for instrumenting code.
"""

from __future__ import annotations

import uuid
from typing import Any

from code_puppy.plugins.agent_trace.schema import (
    AccountingState,
    EventType,
    MetricsInfo,
    NodeInfo,
    NodeKind,
    TokenClass,
    TraceEvent,
    TransferInfo,
    TransferKind,
)


def _make_span_id() -> str:
    """Generate a span ID."""
    return f"span-{uuid.uuid4().hex[:12]}"


def _make_node_id(kind: NodeKind, name: str | None = None) -> str:
    """Generate a node ID with meaningful prefix."""
    suffix = uuid.uuid4().hex[:8]
    if name:
        # Sanitize name for ID
        safe_name = "".join(c if c.isalnum() else "-" for c in name)[:20]
        return f"{kind.value}-{safe_name}-{suffix}"
    return f"{kind.value}-{suffix}"


# ============================================================================
# Span Events
# ============================================================================


def emit_span_started(
    trace_id: str,
    kind: NodeKind,
    name: str | None = None,
    parent_span_id: str | None = None,
    session_id: str | None = None,
    run_id: str | None = None,
    parent_node_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> TraceEvent:
    """Emit a span.started event.

    Use this when:
    - An agent run starts
    - A model call begins
    - A tool call begins
    """
    span_id = _make_span_id()
    node_id = _make_node_id(kind, name)

    return TraceEvent(
        trace_id=trace_id,
        event_type=EventType.SPAN_STARTED,
        span_id=span_id,
        parent_span_id=parent_span_id,
        session_id=session_id,
        run_id=run_id,
        node=NodeInfo(
            id=node_id,
            kind=kind,
            name=name,
            status="running",
            parent_node_id=parent_node_id,
        ),
        extra=extra or {},
    )


def emit_span_ended(
    trace_id: str,
    span_id: str,
    node_id: str,
    kind: NodeKind,
    name: str | None = None,
    success: bool = True,
    error: str | None = None,
    duration_ms: float | None = None,
    session_id: str | None = None,
    run_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> TraceEvent:
    """Emit a span.ended event.

    Use this when:
    - An agent run completes
    - A model call finishes
    - A tool call returns
    """
    return TraceEvent(
        trace_id=trace_id,
        event_type=EventType.SPAN_ENDED,
        span_id=span_id,
        session_id=session_id,
        run_id=run_id,
        node=NodeInfo(
            id=node_id,
            kind=kind,
            name=name,
            status="done" if success else "failed",
        ),
        metrics=MetricsInfo(duration_ms=duration_ms) if duration_ms else None,
        extra={**(extra or {}), "error": error} if error else (extra or {}),
    )


# ============================================================================
# Transfer Events
# ============================================================================


def emit_transfer(
    trace_id: str,
    kind: TransferKind,
    source_node_id: str | None = None,
    target_node_id: str | None = None,
    token_count: int | None = None,
    token_class: TokenClass | None = None,
    accounting: AccountingState = AccountingState.ESTIMATED_LIVE,
    preview: str | None = None,
    message_id: str | None = None,
    session_id: str | None = None,
    span_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> TraceEvent:
    """Emit a transfer event (chunk or completed).

    Use this when:
    - Streaming model output
    - Tool returns result
    - Agent delegates to child
    - Context is assembled for model input
    """
    return TraceEvent(
        trace_id=trace_id,
        event_type=EventType.TRANSFER_CHUNK
        if token_count and token_count < 100
        else EventType.TRANSFER_COMPLETED,
        span_id=span_id,
        session_id=session_id,
        transfer=TransferInfo(
            kind=kind,
            source_node_id=source_node_id,
            target_node_id=target_node_id,
            message_id=message_id,
            token_count=token_count,
            token_class=token_class,
            accounting=accounting,
            preview=preview[:200] if preview else None,  # Truncate previews
        ),
        extra=extra or {},
    )


# ============================================================================
# Usage Events (Accounting State)
# ============================================================================


def emit_usage_reported(
    trace_id: str,
    span_id: str,
    node_id: str,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    reasoning_tokens: int | None = None,
    cached_tokens: int | None = None,
    accounting: AccountingState = AccountingState.ESTIMATED_LIVE,
    cost_usd: float | None = None,
    model_name: str | None = None,
    session_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> TraceEvent:
    """Emit a usage.reported event.

    Use this when:
    - Live streaming estimate is calculated
    - Provider returns usage in response

    The accounting state distinguishes estimated vs exact.
    """
    usage_data = {
        "node_id": node_id,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "reasoning_tokens": reasoning_tokens,
        "cached_tokens": cached_tokens,
        "model_name": model_name,
    }

    return TraceEvent(
        trace_id=trace_id,
        event_type=EventType.USAGE_REPORTED,
        span_id=span_id,
        session_id=session_id,
        transfer=TransferInfo(
            kind=TransferKind.MODEL_OUTPUT,
            source_node_id=node_id,
            token_count=output_tokens,
            token_class=TokenClass.OUTPUT_TOKENS,
            accounting=accounting,
        ),
        metrics=MetricsInfo(cost_usd=cost_usd),
        extra={**(extra or {}), "usage": usage_data},
    )


def emit_usage_reconciled(
    trace_id: str,
    span_id: str,
    node_id: str,
    estimated_input: int | None = None,
    estimated_output: int | None = None,
    exact_input: int | None = None,
    exact_output: int | None = None,
    exact_reasoning: int | None = None,
    exact_cached: int | None = None,
    cost_usd: float | None = None,
    session_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> TraceEvent:
    """Emit a usage.reconciled event.

    This is the key V2 improvement: correct live estimates when exact
    provider usage arrives. This allows the UI to show accurate numbers
    while still being responsive during streaming.
    """
    reconciliation = {
        "node_id": node_id,
        "estimated": {
            "input_tokens": estimated_input,
            "output_tokens": estimated_output,
        },
        "exact": {
            "input_tokens": exact_input,
            "output_tokens": exact_output,
            "reasoning_tokens": exact_reasoning,
            "cached_tokens": exact_cached,
        },
        "drift": {
            "input_tokens": (exact_input - estimated_input)
            if exact_input and estimated_input
            else None,
            "output_tokens": (exact_output - estimated_output)
            if exact_output and estimated_output
            else None,
        },
    }

    return TraceEvent(
        trace_id=trace_id,
        event_type=EventType.USAGE_RECONCILED,
        span_id=span_id,
        session_id=session_id,
        transfer=TransferInfo(
            kind=TransferKind.MODEL_OUTPUT,
            source_node_id=node_id,
            token_count=exact_output,
            token_class=TokenClass.OUTPUT_TOKENS,
            accounting=AccountingState.RECONCILED,
        ),
        metrics=MetricsInfo(cost_usd=cost_usd),
        extra={**(extra or {}), "reconciliation": reconciliation},
    )
