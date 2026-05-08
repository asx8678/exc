"""Agent Trace V2 — Callback Registration.

Hooks into code_puppy's callback system to emit normalized trace events.
Key V2 improvements:
- Model calls are explicit spans (separate from agent runs)
- Token counts have accounting state (estimated vs exact)
- Reconciliation events correct live estimates
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info
from code_puppy.plugins.agent_trace.analytics import (
    analyze_token_budget,
    compare_runs,
    detect_outliers,
    export_csv,
    export_json,
    export_otel,
)
from code_puppy.plugins.agent_trace.cli_analytics import (
    render_comparison,
    render_outlier_report,
    render_token_budget,
    render_trace_summary,
)
from code_puppy.plugins.agent_trace.cli_renderer import (
    clear_previous_render,
    render_live,
    set_render_enabled,
)
from code_puppy.plugins.agent_trace.emitter import (
    emit_span_ended,
    emit_span_started,
    emit_transfer,
    emit_usage_reconciled,
    emit_usage_reported,
)
from code_puppy.plugins.agent_trace.reducer import TraceState, reduce_event
from code_puppy.plugins.agent_trace.schema import (
    AccountingState,
    NodeKind,
    TokenClass,
    TransferKind,
)
from code_puppy.plugins.agent_trace.store import TraceStore

logger = logging.getLogger(__name__)

# Module-level state
_store = TraceStore()
_trace_states: dict[str, TraceState] = {}

# Map session_id -> (trace_id, span_id, node_id) for correlation
_session_spans: dict[str, tuple[str, str, str]] = {}

# Track model call spans within agent runs
_agent_model_spans: dict[
    str, tuple[str, str]
] = {}  # span_id -> (model_span_id, model_node_id)

# Track active tool call span per session (fixes: unique span matching by session)
# This replaces fragile name-based matching which fails when:
# - Same tool runs twice quickly
# - Nested agents call the same tool
# - Retries or partial failures happen
_active_tool_spans: dict[str, str] = {}  # session_id -> span_id for current tool call

# Estimated token counts for reconciliation
_estimated_usage: dict[str, dict[str, int]] = {}  # span_id -> {input, output}


def _get_or_create_trace_id(session_id: str | None) -> str:
    """Get existing trace_id for session or create new one."""
    if session_id and session_id in _session_spans:
        return _session_spans[session_id][0]
    return f"trace-{uuid.uuid4().hex[:12]}"


def _on_startup():
    """Initialize the trace system."""
    emit_info("📊 Agent Trace V2 loaded (live CLI visualization enabled)")


async def _on_agent_run_start(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    **kwargs,
) -> None:
    """Handle agent run start — create agent_run span and model_call span."""
    try:
        trace_id = _get_or_create_trace_id(session_id)

        # Determine parent span if this is a child agent
        parent_span_id = None
        parent_node_id = None
        if session_id:
            # Check if there's a parent session
            parent_session = kwargs.get("parent_session_id")
            if parent_session and parent_session in _session_spans:
                _, parent_span_id, parent_node_id = _session_spans[parent_session]

        # Create agent_run span
        agent_event = emit_span_started(
            trace_id=trace_id,
            kind=NodeKind.AGENT_RUN,
            name=agent_name,
            parent_span_id=parent_span_id,
            session_id=session_id,
            parent_node_id=parent_node_id,
            extra={"model": model_name},
        )

        # Store the mapping
        if session_id and agent_event.span_id and agent_event.node:
            _session_spans[session_id] = (
                trace_id,
                agent_event.span_id,
                agent_event.node.id,
            )

        # Create model_call span as child (V2: explicit model node!)
        model_event = emit_span_started(
            trace_id=trace_id,
            kind=NodeKind.MODEL_CALL,
            name=model_name,
            parent_span_id=agent_event.span_id,
            session_id=session_id,
            parent_node_id=agent_event.node.id if agent_event.node else None,
        )

        # Track model span for later
        if agent_event.span_id and model_event.span_id and model_event.node:
            _agent_model_spans[agent_event.span_id] = (
                model_event.span_id,
                model_event.node.id,
            )

        # Initialize trace state
        if trace_id not in _trace_states:
            _trace_states[trace_id] = TraceState(trace_id=trace_id)

        # Reduce events into state
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], agent_event)
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], model_event)

        # Persist events
        _store.append(agent_event)
        _store.append(model_event)

        # Render live trace
        if trace_id in _trace_states:
            render_live(_trace_states[trace_id], mode="tree")

    except Exception as e:
        logger.debug(f"Agent trace error in agent_run_start: {e}")


async def _on_stream_event(
    event_type: str,
    event_data: Any,
    agent_session_id: str | None = None,
    **kwargs,
) -> None:
    """Handle stream events — emit transfer events with estimated tokens.

    Expects normalized event data following the unified schema:
    {
        "content_delta": str | None, # Text/thinking content delta
        "args_delta": str | None, # Tool args delta
        "tool_name": str | None, # Current tool name
        "tool_name_delta": str | None, # Tool name delta (streaming)
        "part_kind": str, # "text", "thinking", "tool_call", etc.
        "index": int,
        "raw": dict, # Original event for debugging
    }
    """
    try:
        if agent_session_id not in _session_spans:
            return

        trace_id, agent_span_id, agent_node_id = _session_spans[agent_session_id]

        # Get model span if available
        model_span_id, model_node_id = _agent_model_spans.get(
            agent_span_id, (None, None)
        )
        source_node = model_node_id or agent_node_id

        # Estimate tokens from normalized stream chunk
        token_count = None
        content_parts: list[str] = []

        if isinstance(event_data, dict):
            # Use unified schema fields for token estimation
            content_delta = event_data.get("content_delta")
            args_delta = event_data.get("args_delta")
            tool_name_delta = event_data.get("tool_name_delta")

            if content_delta:
                content_parts.append(str(content_delta))
            if args_delta:
                content_parts.append(str(args_delta))
            if tool_name_delta:
                content_parts.append(str(tool_name_delta))

            if content_parts:
                # Rough estimate: ~4 chars per token
                content = "".join(content_parts)
                token_count = max(1, len(content) // 4)

        if token_count:
            transfer_event = emit_transfer(
                trace_id=trace_id,
                kind=TransferKind.MODEL_OUTPUT,
                source_node_id=source_node,
                target_node_id=agent_node_id,
                token_count=token_count,
                token_class=TokenClass.OUTPUT_TOKENS,
                accounting=AccountingState.ESTIMATED_LIVE,
                span_id=model_span_id or agent_span_id,
                session_id=agent_session_id,
            )

            # Track estimated usage for reconciliation
            span_key = model_span_id or agent_span_id
            if span_key:
                if span_key not in _estimated_usage:
                    _estimated_usage[span_key] = {"input": 0, "output": 0}
                _estimated_usage[span_key]["output"] += token_count

            # Reduce and persist
            _trace_states[trace_id] = reduce_event(
                _trace_states[trace_id], transfer_event
            )
            _store.append(transfer_event)

        # Live render update
        if trace_id in _trace_states:
            render_live(_trace_states[trace_id], mode="tree")

    except Exception as e:
        logger.debug(f"Agent trace error in stream_event: {e}")


async def _on_pre_tool_call(
    tool_name: str,
    tool_args: dict[str, Any],
    context: Any = None,
    **kwargs,
) -> None:
    """Handle tool call start — create tool_call span."""
    try:
        # Get session from context
        session_id = getattr(context, "session_id", None) if context else None
        if not session_id or session_id not in _session_spans:
            return

        trace_id, agent_span_id, agent_node_id = _session_spans[session_id]
        model_span_id, model_node_id = _agent_model_spans.get(
            agent_span_id, (None, None)
        )

        # Create tool_call span
        tool_event = emit_span_started(
            trace_id=trace_id,
            kind=NodeKind.TOOL_CALL,
            name=tool_name,
            parent_span_id=model_span_id or agent_span_id,
            session_id=session_id,
            parent_node_id=model_node_id or agent_node_id,
        )

        # Emit tool_args transfer
        args_str = str(tool_args)[:500]  # Truncate for storage
        args_event = emit_transfer(
            trace_id=trace_id,
            kind=TransferKind.TOOL_ARGS,
            source_node_id=model_node_id or agent_node_id,
            target_node_id=tool_event.node.id if tool_event.node else None,
            token_count=len(args_str) // 4,  # Rough estimate
            token_class=TokenClass.INPUT_TOKENS,
            accounting=AccountingState.ESTIMATED_LIVE,
            preview=args_str[:200],
            span_id=tool_event.span_id,
            session_id=session_id,
        )

        # Reduce and persist
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], tool_event)
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], args_event)
        _store.append(tool_event)
        _store.append(args_event)

        # Store span_id for reliable lookup in _on_post_tool_call
        # This fixes: unique span matching per session instead of fragile name-based search
        _active_tool_spans[session_id] = tool_event.span_id

    except Exception as e:
        logger.debug(f"Agent trace error in pre_tool_call: {e}")


async def _on_post_tool_call(
    tool_name: str,
    tool_args: dict[str, Any],
    result: Any,
    duration_ms: float,
    context: Any = None,
    **kwargs,
) -> None:
    """Handle tool call end — emit tool_result and close span."""
    try:
        session_id = getattr(context, "session_id", None) if context else None
        if not session_id or session_id not in _session_spans:
            return

        trace_id, agent_span_id, agent_node_id = _session_spans[session_id]

        # Find the tool span using unique session-based lookup
        # This replaces fragile name-based matching that failed when:
        # - Same tool runs twice quickly
        # - Nested agents call the same tool
        # - Retries or partial failures happen
        state = _trace_states.get(trace_id)
        if not state:
            return

        tool_span = None
        span_id = _active_tool_spans.pop(session_id, None)
        if span_id and span_id in state.spans:
            tool_span = state.spans[span_id]
        else:
            # Fallback to name-based search for backward compatibility
            # if span was created before this fix or cleanup failed
            for span in reversed(list(state.spans.values())):
                if (
                    span.kind == NodeKind.TOOL_CALL
                    and span.name == tool_name
                    and span.status == "running"
                ):
                    tool_span = span
                    break

        if not tool_span:
            return

        # Emit tool_result transfer
        result_str = str(result)[:500]
        result_event = emit_transfer(
            trace_id=trace_id,
            kind=TransferKind.TOOL_RESULT,
            source_node_id=tool_span.node_id,
            target_node_id=agent_node_id,
            token_count=len(result_str) // 4,
            token_class=TokenClass.INPUT_TOKENS,  # Tool results become model input
            accounting=AccountingState.ESTIMATED_LIVE,
            preview=result_str[:200],
            span_id=tool_span.span_id,
            session_id=session_id,
        )

        # End tool span
        end_event = emit_span_ended(
            trace_id=trace_id,
            span_id=tool_span.span_id,
            node_id=tool_span.node_id,
            kind=NodeKind.TOOL_CALL,
            name=tool_name,
            success=True,
            duration_ms=duration_ms,
            session_id=session_id,
        )

        # Reduce and persist
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], result_event)
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], end_event)
        _store.append(result_event)
        _store.append(end_event)

        # Render updated state
        if trace_id in _trace_states:
            render_live(_trace_states[trace_id], mode="tree")

    except Exception as e:
        logger.debug(f"Agent trace error in post_tool_call: {e}")


async def _on_agent_run_end(
    agent_name: str,
    model_name: str,
    session_id: str | None = None,
    success: bool = True,
    error: Exception | None = None,
    response_text: str | None = None,
    metadata: dict | None = None,
    **kwargs,
) -> None:
    """Handle agent run end — close spans and emit reconciliation."""
    try:
        if not session_id or session_id not in _session_spans:
            return

        trace_id, agent_span_id, agent_node_id = _session_spans[session_id]
        model_span_id, model_node_id = _agent_model_spans.get(
            agent_span_id, (None, None)
        )

        # Extract exact usage from metadata if available
        exact_usage = None
        if metadata:
            exact_usage = metadata.get("usage") or metadata.get("token_usage")

        # End model span first
        if model_span_id and model_node_id:
            # Emit usage_reported with exact provider numbers
            if exact_usage:
                usage_event = emit_usage_reported(
                    trace_id=trace_id,
                    span_id=model_span_id,
                    node_id=model_node_id,
                    input_tokens=exact_usage.get("input_tokens")
                    or exact_usage.get("prompt_tokens"),
                    output_tokens=exact_usage.get("output_tokens")
                    or exact_usage.get("completion_tokens"),
                    reasoning_tokens=exact_usage.get("reasoning_tokens"),
                    cached_tokens=exact_usage.get("cache_read_tokens")
                    or exact_usage.get("cached_tokens"),
                    accounting=AccountingState.PROVIDER_REPORTED_EXACT,
                    model_name=model_name,
                    session_id=session_id,
                )
                _trace_states[trace_id] = reduce_event(
                    _trace_states[trace_id], usage_event
                )
                _store.append(usage_event)

            # Check if we have exact usage to emit reconciliation
            if exact_usage and model_span_id in _estimated_usage:
                estimated = _estimated_usage[model_span_id]
                recon_event = emit_usage_reconciled(
                    trace_id=trace_id,
                    span_id=model_span_id,
                    node_id=model_node_id,
                    estimated_input=estimated.get("input"),
                    estimated_output=estimated.get("output"),
                    exact_input=exact_usage.get("input_tokens")
                    or exact_usage.get("prompt_tokens"),
                    exact_output=exact_usage.get("output_tokens")
                    or exact_usage.get("completion_tokens"),
                    exact_reasoning=exact_usage.get("reasoning_tokens"),
                    exact_cached=exact_usage.get("cache_read_tokens")
                    or exact_usage.get("cached_tokens"),
                    session_id=session_id,
                )
                _trace_states[trace_id] = reduce_event(
                    _trace_states[trace_id], recon_event
                )
                _store.append(recon_event)

            model_end = emit_span_ended(
                trace_id=trace_id,
                span_id=model_span_id,
                node_id=model_node_id,
                kind=NodeKind.MODEL_CALL,
                name=model_name,
                success=success,
                error=str(error) if error else None,
                session_id=session_id,
            )
            _trace_states[trace_id] = reduce_event(_trace_states[trace_id], model_end)
            _store.append(model_end)

        # End agent span
        agent_end = emit_span_ended(
            trace_id=trace_id,
            span_id=agent_span_id,
            node_id=agent_node_id,
            kind=NodeKind.AGENT_RUN,
            name=agent_name,
            success=success,
            error=str(error) if error else None,
            session_id=session_id,
        )
        _trace_states[trace_id] = reduce_event(_trace_states[trace_id], agent_end)
        _store.append(agent_end)

        # Final render with reconciliation
        if trace_id in _trace_states:
            render_live(_trace_states[trace_id], mode="tree", force=True)

        # Auto-analyze for outliers and show summary
        if trace_id in _trace_states:
            state = _trace_states[trace_id]
            events = _store.read(trace_id)
            budget = analyze_token_budget(state, events)
            outliers = detect_outliers(state)

            # Show compact summary if there are outliers or significant token usage
            if outliers.outliers or budget.total() > 500:
                print(render_trace_summary(budget, outliers))

        # Cleanup
        if model_span_id in _estimated_usage:
            del _estimated_usage[model_span_id]
        if agent_span_id in _agent_model_spans:
            del _agent_model_spans[agent_span_id]

    except Exception as e:
        logger.debug(f"Agent trace error in agent_run_end: {e}")


def _custom_help():
    """Provide help for trace commands."""
    return [
        (
            "trace",
            "Agent trace: /trace on|off|status|list|show|budget|compare|analyze|export",
        ),
    ]


def _handle_trace_command(command: str, name: str) -> Any:
    """Handle /trace slash commands."""
    if name != "trace":
        return None

    parts = command.strip().split()
    subcommand = parts[1] if len(parts) > 1 else "status"

    if subcommand == "on":
        set_render_enabled(True)
        emit_info("📊 Live trace rendering enabled")
        return True

    if subcommand == "off":
        set_render_enabled(False)
        clear_previous_render()
        emit_info("📊 Live trace rendering disabled")
        return True

    if subcommand == "status":
        active = sum(
            1
            for s in _trace_states.values()
            for sp in s.spans.values()
            if sp.status == "running"
        )
        total = sum(len(s.spans) for s in _trace_states.values())
        emit_info(
            f"📊 Active spans: {active}, Total spans: {total}, Traces: {len(_trace_states)}"
        )
        return True

    if subcommand == "list":
        traces = _store.list_traces()
        if not traces:
            emit_info("📊 No stored traces")
        else:
            emit_info(
                f"📊 Stored traces: {', '.join(traces[:10])}"
                + (f" (+{len(traces) - 10} more)" if len(traces) > 10 else "")
            )
        return True

    if subcommand == "show" and len(parts) > 2:
        trace_id = parts[2]
        events = _store.read(trace_id)
        emit_info(f"📊 Trace {trace_id}: {len(events)} events")
        return True

    if subcommand == "budget":
        # Show token budget for current or specified trace
        trace_id = parts[2] if len(parts) > 2 else None

        if trace_id:
            # Load from store
            events = _store.read(trace_id)
            if not events:
                emit_info(f"📊 Trace {trace_id} not found")
                return True
            from code_puppy.plugins.agent_trace.reducer import replay_trace

            state = replay_trace(events)
        elif _trace_states:
            # Use most recent active trace
            trace_id = list(_trace_states.keys())[-1]
            state = _trace_states[trace_id]
            events = _store.read(trace_id)
        else:
            emit_info("📊 No active traces. Use /trace budget <trace_id>")
            return True

        budget = analyze_token_budget(state, events)
        print(render_token_budget(budget))
        return True

    if subcommand == "compare" and len(parts) > 3:
        trace1_id = parts[2]
        trace2_id = parts[3]

        # Load both traces
        events1 = _store.read(trace1_id)
        events2 = _store.read(trace2_id)

        if not events1:
            emit_info(f"📊 Trace {trace1_id} not found")
            return True
        if not events2:
            emit_info(f"📊 Trace {trace2_id} not found")
            return True

        from code_puppy.plugins.agent_trace.reducer import replay_trace

        state1 = replay_trace(events1)
        state2 = replay_trace(events2)

        comparison = compare_runs(state1, state2)
        print(render_comparison(comparison))
        return True

    if subcommand == "analyze":
        # Run outlier detection
        trace_id = parts[2] if len(parts) > 2 else None

        if trace_id:
            events = _store.read(trace_id)
            if not events:
                emit_info(f"📊 Trace {trace_id} not found")
                return True
            from code_puppy.plugins.agent_trace.reducer import replay_trace

            state = replay_trace(events)
        elif _trace_states:
            trace_id = list(_trace_states.keys())[-1]
            state = _trace_states[trace_id]
        else:
            emit_info("📊 No active traces. Use /trace analyze <trace_id>")
            return True

        outliers = detect_outliers(state)
        print(render_outlier_report(outliers))
        return True

    if subcommand == "export" and len(parts) > 2:
        trace_id = parts[2]
        format_type = parts[3] if len(parts) > 3 else "json"

        events = _store.read(trace_id)
        if not events:
            emit_info(f"📊 Trace {trace_id} not found")
            return True

        from code_puppy.plugins.agent_trace.reducer import replay_trace

        state = replay_trace(events)

        if format_type == "json":
            import json

            output = json.dumps(export_json(state, events), indent=2)
        elif format_type == "otel":
            import json

            output = json.dumps(export_otel(state, events), indent=2)
        elif format_type == "csv":
            output = export_csv(state)
        else:
            emit_info(f"📊 Unknown format: {format_type}. Use json, otel, or csv")
            return True

        # Write to file
        filename = f"{trace_id}.{format_type}"
        with open(filename, "w") as f:
            f.write(output)
        emit_info(f"📊 Exported to {filename}")
        return True

    if subcommand == "clear":
        _trace_states.clear()
        _session_spans.clear()
        _agent_model_spans.clear()
        _estimated_usage.clear()
        emit_info("📊 Trace state cleared")
        return True

    emit_info(
        "Usage: /trace on|off|status|list|show <id>|budget [id]|compare <t1> <t2>|analyze [id]|export <id> [json|otel|csv]|clear"
    )
    return True


# Register all callbacks
register_callback("startup", _on_startup)
register_callback("agent_run_start", _on_agent_run_start)
register_callback("stream_event", _on_stream_event)
register_callback("pre_tool_call", _on_pre_tool_call)
register_callback("post_tool_call", _on_post_tool_call)
register_callback("agent_run_end", _on_agent_run_end)
register_callback("custom_command_help", _custom_help)
register_callback("custom_command", _handle_trace_command)
