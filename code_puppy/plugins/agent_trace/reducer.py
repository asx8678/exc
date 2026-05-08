"""Agent Trace V2 — State Reducer.

Pure functions for reducing trace events into UI-ready state.
Separates model calls from agent runs as explicit nodes.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from code_puppy.plugins.agent_trace.schema import (
    AccountingState,
    EventType,
    NodeKind,
    TraceEvent,
)


@dataclass
class TokenUsage:
    """Token usage with accounting state tracking."""

    input_tokens: int = 0
    output_tokens: int = 0
    reasoning_tokens: int = 0
    cached_tokens: int = 0
    accounting: AccountingState = AccountingState.UNKNOWN

    # Track estimated vs exact for reconciliation
    estimated_input: int | None = None
    estimated_output: int | None = None
    reconciled: bool = False

    def total(self) -> int:
        return self.input_tokens + self.output_tokens

    def is_exact(self) -> bool:
        return self.accounting in (
            AccountingState.PROVIDER_REPORTED_EXACT,
            AccountingState.RECONCILED,
        )


@dataclass
class SpanState:
    """State for a single span (agent, model, or tool)."""

    span_id: str
    node_id: str
    kind: NodeKind
    name: str | None
    status: str = "running"
    parent_span_id: str | None = None
    parent_node_id: str | None = None

    started_at: float = field(default_factory=time.time)
    ended_at: float | None = None
    duration_ms: float | None = None

    usage: TokenUsage = field(default_factory=TokenUsage)
    error: str | None = None

    # Child spans (model calls within agent, tool calls within model)
    child_span_ids: list[str] = field(default_factory=list)


@dataclass
class TraceState:
    """Full state for a trace (session/run).

    Key V2 improvement: spans are keyed by span_id, and model_call
    spans are explicit children of agent_run spans.
    """

    trace_id: str
    spans: dict[str, SpanState] = field(default_factory=dict)

    # Ordered lists for timeline view
    span_order: list[str] = field(default_factory=list)

    # Aggregated metrics
    total_input_tokens: int = 0
    total_output_tokens: int = 0
    total_cost_usd: float = 0.0

    # Track which estimates need reconciliation
    pending_reconciliation: set[str] = field(default_factory=set)

    created_at: float = field(default_factory=time.time)

    def active_spans(self) -> list[SpanState]:
        """Get all currently running spans."""
        return [s for s in self.spans.values() if s.status == "running"]

    def model_calls(self) -> list[SpanState]:
        """Get all model call spans."""
        return [s for s in self.spans.values() if s.kind == NodeKind.MODEL_CALL]

    def agent_runs(self) -> list[SpanState]:
        """Get all agent run spans."""
        return [s for s in self.spans.values() if s.kind == NodeKind.AGENT_RUN]

    def tool_calls(self) -> list[SpanState]:
        """Get all tool call spans."""
        return [s for s in self.spans.values() if s.kind == NodeKind.TOOL_CALL]


def reduce_event(state: TraceState, event: TraceEvent) -> TraceState:
    """Apply a trace event to produce new state.

    This is a pure reducer function — no side effects.
    """
    if event.event_type == EventType.SPAN_STARTED:
        return _reduce_span_started(state, event)
    elif event.event_type == EventType.SPAN_ENDED:
        return _reduce_span_ended(state, event)
    elif event.event_type in (EventType.TRANSFER_CHUNK, EventType.TRANSFER_COMPLETED):
        return _reduce_transfer(state, event)
    elif event.event_type == EventType.USAGE_REPORTED:
        return _reduce_usage_reported(state, event)
    elif event.event_type == EventType.USAGE_RECONCILED:
        return _reduce_usage_reconciled(state, event)
    else:
        return state


def _reduce_span_started(state: TraceState, event: TraceEvent) -> TraceState:
    """Handle span.started event."""
    if not event.span_id or not event.node:
        return state

    node = event.node
    span = SpanState(
        span_id=event.span_id,
        node_id=node.id,
        kind=node.kind,
        name=node.name,
        status="running",
        parent_span_id=event.parent_span_id,
        parent_node_id=node.parent_node_id,
    )

    # Add to state
    new_spans = {**state.spans, event.span_id: span}
    new_order = state.span_order + [event.span_id]

    # Update parent's child list if applicable
    if event.parent_span_id and event.parent_span_id in new_spans:
        parent = new_spans[event.parent_span_id]
        new_spans[event.parent_span_id] = SpanState(
            span_id=parent.span_id,
            node_id=parent.node_id,
            kind=parent.kind,
            name=parent.name,
            status=parent.status,
            parent_span_id=parent.parent_span_id,
            parent_node_id=parent.parent_node_id,
            started_at=parent.started_at,
            ended_at=parent.ended_at,
            duration_ms=parent.duration_ms,
            usage=parent.usage,
            error=parent.error,
            child_span_ids=parent.child_span_ids + [event.span_id],
        )

    return TraceState(
        trace_id=state.trace_id,
        spans=new_spans,
        span_order=new_order,
        total_input_tokens=state.total_input_tokens,
        total_output_tokens=state.total_output_tokens,
        total_cost_usd=state.total_cost_usd,
        pending_reconciliation=state.pending_reconciliation,
        created_at=state.created_at,
    )


def _reduce_span_ended(state: TraceState, event: TraceEvent) -> TraceState:
    """Handle span.ended event."""
    if not event.span_id or event.span_id not in state.spans:
        return state

    span = state.spans[event.span_id]
    ended_at = time.time()
    duration_ms = (ended_at - span.started_at) * 1000

    # Get status and error from event
    status = "done"
    error = None
    if event.node and event.node.status:
        status = event.node.status
    if event.extra and "error" in event.extra:
        error = str(event.extra["error"])
        status = "failed"

    # Update metrics from event
    if event.metrics and event.metrics.duration_ms:
        duration_ms = event.metrics.duration_ms

    updated_span = SpanState(
        span_id=span.span_id,
        node_id=span.node_id,
        kind=span.kind,
        name=span.name,
        status=status,
        parent_span_id=span.parent_span_id,
        parent_node_id=span.parent_node_id,
        started_at=span.started_at,
        ended_at=ended_at,
        duration_ms=duration_ms,
        usage=span.usage,
        error=error,
        child_span_ids=span.child_span_ids,
    )

    return TraceState(
        trace_id=state.trace_id,
        spans={**state.spans, event.span_id: updated_span},
        span_order=state.span_order,
        total_input_tokens=state.total_input_tokens,
        total_output_tokens=state.total_output_tokens,
        total_cost_usd=state.total_cost_usd,
        pending_reconciliation=state.pending_reconciliation,
        created_at=state.created_at,
    )


def _reduce_transfer(state: TraceState, event: TraceEvent) -> TraceState:
    """Handle transfer events (tokens moving between nodes)."""
    if not event.transfer or not event.span_id:
        return state

    if event.span_id not in state.spans:
        return state

    transfer = event.transfer
    span = state.spans[event.span_id]

    # Update token counts based on transfer
    new_usage = TokenUsage(
        input_tokens=span.usage.input_tokens,
        output_tokens=span.usage.output_tokens,
        reasoning_tokens=span.usage.reasoning_tokens,
        cached_tokens=span.usage.cached_tokens,
        accounting=transfer.accounting,
        estimated_input=span.usage.estimated_input,
        estimated_output=span.usage.estimated_output,
        reconciled=span.usage.reconciled,
    )

    if transfer.token_count:
        from code_puppy.plugins.agent_trace.schema import TokenClass

        if transfer.token_class == TokenClass.INPUT_TOKENS:
            new_usage.input_tokens += transfer.token_count
        elif transfer.token_class == TokenClass.OUTPUT_TOKENS:
            new_usage.output_tokens += transfer.token_count
        elif transfer.token_class == TokenClass.REASONING_TOKENS:
            new_usage.reasoning_tokens += transfer.token_count
        elif transfer.token_class == TokenClass.CACHED_TOKENS:
            new_usage.cached_tokens += transfer.token_count

    updated_span = SpanState(
        span_id=span.span_id,
        node_id=span.node_id,
        kind=span.kind,
        name=span.name,
        status=span.status,
        parent_span_id=span.parent_span_id,
        parent_node_id=span.parent_node_id,
        started_at=span.started_at,
        ended_at=span.ended_at,
        duration_ms=span.duration_ms,
        usage=new_usage,
        error=span.error,
        child_span_ids=span.child_span_ids,
    )

    # Track pending reconciliation for estimated usage
    pending = set(state.pending_reconciliation)
    if transfer.accounting == AccountingState.ESTIMATED_LIVE:
        pending.add(event.span_id)

    return TraceState(
        trace_id=state.trace_id,
        spans={**state.spans, event.span_id: updated_span},
        span_order=state.span_order,
        total_input_tokens=state.total_input_tokens,
        total_output_tokens=state.total_output_tokens,
        total_cost_usd=state.total_cost_usd,
        pending_reconciliation=pending,
        created_at=state.created_at,
    )


def _reduce_usage_reported(state: TraceState, event: TraceEvent) -> TraceState:
    """Handle usage.reported event."""
    if not event.span_id or event.span_id not in state.spans:
        return state

    span = state.spans[event.span_id]
    usage_data = event.extra.get("usage", {}) if event.extra else {}

    new_usage = TokenUsage(
        input_tokens=usage_data["input_tokens"]
        if usage_data.get("input_tokens") is not None
        else span.usage.input_tokens,
        output_tokens=usage_data["output_tokens"]
        if usage_data.get("output_tokens") is not None
        else span.usage.output_tokens,
        reasoning_tokens=usage_data["reasoning_tokens"]
        if usage_data.get("reasoning_tokens") is not None
        else span.usage.reasoning_tokens,
        cached_tokens=usage_data["cached_tokens"]
        if usage_data.get("cached_tokens") is not None
        else span.usage.cached_tokens,
        accounting=event.transfer.accounting
        if event.transfer
        else span.usage.accounting,
        estimated_input=span.usage.estimated_input,
        estimated_output=span.usage.estimated_output,
        reconciled=span.usage.reconciled,
    )

    # Track estimated values for later reconciliation
    if event.transfer and event.transfer.accounting == AccountingState.ESTIMATED_LIVE:
        new_usage.estimated_input = new_usage.input_tokens
        new_usage.estimated_output = new_usage.output_tokens

    updated_span = SpanState(
        span_id=span.span_id,
        node_id=span.node_id,
        kind=span.kind,
        name=span.name,
        status=span.status,
        parent_span_id=span.parent_span_id,
        parent_node_id=span.parent_node_id,
        started_at=span.started_at,
        ended_at=span.ended_at,
        duration_ms=span.duration_ms,
        usage=new_usage,
        error=span.error,
        child_span_ids=span.child_span_ids,
    )

    # Update totals
    cost = event.metrics.cost_usd if event.metrics else 0.0

    return TraceState(
        trace_id=state.trace_id,
        spans={**state.spans, event.span_id: updated_span},
        span_order=state.span_order,
        total_input_tokens=state.total_input_tokens
        + (usage_data.get("input_tokens") or 0),
        total_output_tokens=state.total_output_tokens
        + (usage_data.get("output_tokens") or 0),
        total_cost_usd=state.total_cost_usd + (cost or 0.0),
        pending_reconciliation=state.pending_reconciliation,
        created_at=state.created_at,
    )


def _reduce_usage_reconciled(state: TraceState, event: TraceEvent) -> TraceState:
    """Handle usage.reconciled event — the key V2 improvement.

    This corrects live estimates when exact provider usage arrives.
    """
    if not event.span_id or event.span_id not in state.spans:
        return state

    span = state.spans[event.span_id]
    reconciliation = event.extra.get("reconciliation", {}) if event.extra else {}
    exact = reconciliation.get("exact", {})

    # Use exact values when provided (even if 0), fall back to existing only when None
    new_usage = TokenUsage(
        input_tokens=exact["input_tokens"]
        if exact.get("input_tokens") is not None
        else span.usage.input_tokens,
        output_tokens=exact["output_tokens"]
        if exact.get("output_tokens") is not None
        else span.usage.output_tokens,
        reasoning_tokens=exact["reasoning_tokens"]
        if exact.get("reasoning_tokens") is not None
        else span.usage.reasoning_tokens,
        cached_tokens=exact["cached_tokens"]
        if exact.get("cached_tokens") is not None
        else span.usage.cached_tokens,
        accounting=AccountingState.RECONCILED,
        estimated_input=span.usage.estimated_input,
        estimated_output=span.usage.estimated_output,
        reconciled=True,
    )

    updated_span = SpanState(
        span_id=span.span_id,
        node_id=span.node_id,
        kind=span.kind,
        name=span.name,
        status=span.status,
        parent_span_id=span.parent_span_id,
        parent_node_id=span.parent_node_id,
        started_at=span.started_at,
        ended_at=span.ended_at,
        duration_ms=span.duration_ms,
        usage=new_usage,
        error=span.error,
        child_span_ids=span.child_span_ids,
    )

    # Remove from pending reconciliation
    pending = state.pending_reconciliation - {event.span_id}

    # Recalculate totals with corrected values
    drift = reconciliation.get("drift", {})
    input_drift = drift.get("input_tokens") or 0
    output_drift = drift.get("output_tokens") or 0

    return TraceState(
        trace_id=state.trace_id,
        spans={**state.spans, event.span_id: updated_span},
        span_order=state.span_order,
        total_input_tokens=state.total_input_tokens + input_drift,
        total_output_tokens=state.total_output_tokens + output_drift,
        total_cost_usd=state.total_cost_usd,
        pending_reconciliation=pending,
        created_at=state.created_at,
    )


def replay_trace(events: list[TraceEvent]) -> TraceState:
    """Replay a list of events to reconstruct state.

    Use this for loading persisted traces.
    """
    if not events:
        return TraceState(trace_id="")

    state = TraceState(trace_id=events[0].trace_id)
    for event in events:
        state = reduce_event(state, event)

    return state
