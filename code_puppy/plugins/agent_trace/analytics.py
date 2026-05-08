"""Agent Trace V2 — Analytics & Comparison.

Provides:
- Token budget breakdown (where did tokens go?)
- Run comparison (find regressions)
- Outlier detection (loops, bloat, retry storms)
- Metrics aggregation
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from code_puppy.plugins.agent_trace.reducer import SpanState, TraceState
from code_puppy.plugins.agent_trace.schema import (
    AccountingState,
    NodeKind,
    TraceEvent,
    TransferKind,
)

# ═══════════════════════════════════════════════════════════════════════════════
# Token Budget Analysis
# ═══════════════════════════════════════════════════════════════════════════════


@dataclass
class TokenBudget:
    """Breakdown of token usage by category."""

    system_prompt: int = 0
    history_context: int = 0
    retrieved_context: int = 0
    tool_results: int = 0
    tool_args: int = 0
    model_input: int = 0
    model_output: int = 0
    reasoning: int = 0
    delegate_prompt: int = 0
    delegate_response: int = 0

    # Accounting
    estimated_total: int = 0
    exact_total: int = 0
    reconciled: bool = False

    # Cost estimate (if available)
    estimated_cost_usd: float | None = None

    def total(self) -> int:
        """Total tokens across all categories."""
        return (
            self.system_prompt
            + self.history_context
            + self.retrieved_context
            + self.tool_results
            + self.tool_args
            + self.model_output
            + self.reasoning
            + self.delegate_prompt
            + self.delegate_response
        )

    def input_total(self) -> int:
        """Total input tokens."""
        return (
            self.system_prompt
            + self.history_context
            + self.retrieved_context
            + self.tool_results
            + self.model_input
        )

    def output_total(self) -> int:
        """Total output tokens."""
        return self.model_output + self.reasoning

    def breakdown(self) -> list[tuple[str, int, float]]:
        """Get breakdown as list of (category, tokens, percentage)."""
        total = self.total()
        if total == 0:
            return []

        items = [
            ("System prompt", self.system_prompt),
            ("History context", self.history_context),
            ("Retrieved context", self.retrieved_context),
            ("Tool results", self.tool_results),
            ("Tool args", self.tool_args),
            ("Model output", self.model_output),
            ("Reasoning", self.reasoning),
            ("Delegate prompt", self.delegate_prompt),
            ("Delegate response", self.delegate_response),
        ]

        return [
            (name, count, count / total * 100) for name, count in items if count > 0
        ]


def analyze_token_budget(
    state: TraceState, events: list[TraceEvent] | None = None
) -> TokenBudget:
    """Analyze token budget from trace state and/or events.

    Args:
        state: The reduced trace state
        events: Optional raw events for more detailed analysis

    Returns:
        TokenBudget with breakdown by category
    """
    budget = TokenBudget()

    # Analyze from events if available (more detailed)
    if events:
        for event in events:
            if not event.transfer:
                continue

            transfer = event.transfer
            tokens = transfer.token_count or 0

            if transfer.kind == TransferKind.SYSTEM_INSTRUCTIONS:
                budget.system_prompt += tokens
            elif transfer.kind == TransferKind.HISTORY_CONTEXT:
                budget.history_context += tokens
            elif transfer.kind == TransferKind.RETRIEVED_CONTEXT:
                budget.retrieved_context += tokens
            elif transfer.kind == TransferKind.TOOL_RESULT:
                budget.tool_results += tokens
            elif transfer.kind == TransferKind.TOOL_ARGS:
                budget.tool_args += tokens
            elif transfer.kind == TransferKind.MODEL_OUTPUT:
                budget.model_output += tokens
            elif transfer.kind == TransferKind.MODEL_INPUT:
                budget.model_input += tokens
            elif transfer.kind == TransferKind.DELEGATE_PROMPT:
                budget.delegate_prompt += tokens
            elif transfer.kind == TransferKind.DELEGATE_RESPONSE:
                budget.delegate_response += tokens

            # Track accounting state
            if transfer.accounting == AccountingState.RECONCILED:
                budget.reconciled = True
            if transfer.accounting == AccountingState.ESTIMATED_LIVE:
                budget.estimated_total += tokens
            elif transfer.accounting == AccountingState.PROVIDER_REPORTED_EXACT:
                budget.exact_total += tokens

    # Also aggregate from spans
    for span in state.spans.values():
        if span.kind == NodeKind.MODEL_CALL:
            if span.usage.reasoning_tokens:
                budget.reasoning += span.usage.reasoning_tokens

    return budget


# ═══════════════════════════════════════════════════════════════════════════════
# Run Comparison
# ═══════════════════════════════════════════════════════════════════════════════


@dataclass
class RunMetrics:
    """Aggregated metrics for a single run."""

    trace_id: str
    duration_ms: float = 0.0
    total_tokens: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    model_calls: int = 0
    tool_calls: int = 0
    agent_runs: int = 0
    failed_spans: int = 0
    avg_span_duration_ms: float = 0.0
    max_span_duration_ms: float = 0.0

    @classmethod
    def from_state(cls, state: TraceState) -> RunMetrics:
        """Compute metrics from trace state."""
        metrics = cls(trace_id=state.trace_id)

        durations = []
        for span in state.spans.values():
            if span.kind == NodeKind.MODEL_CALL:
                metrics.model_calls += 1
            elif span.kind == NodeKind.TOOL_CALL:
                metrics.tool_calls += 1
            elif span.kind == NodeKind.AGENT_RUN:
                metrics.agent_runs += 1

            if span.status == "failed":
                metrics.failed_spans += 1

            metrics.input_tokens += span.usage.input_tokens
            metrics.output_tokens += span.usage.output_tokens

            if span.duration_ms:
                durations.append(span.duration_ms)

        metrics.total_tokens = metrics.input_tokens + metrics.output_tokens

        if durations:
            metrics.avg_span_duration_ms = sum(durations) / len(durations)
            metrics.max_span_duration_ms = max(durations)
            # Total duration is max of root spans
            root_spans = [s for s in state.spans.values() if not s.parent_span_id]
            if root_spans:
                metrics.duration_ms = max(s.duration_ms or 0 for s in root_spans)

        return metrics


@dataclass
class RunComparison:
    """Comparison between two runs."""

    baseline: RunMetrics
    current: RunMetrics

    duration_delta_pct: float = 0.0
    tokens_delta_pct: float = 0.0
    model_calls_delta: int = 0
    tool_calls_delta: int = 0

    is_regression: bool = False
    regression_reasons: list[str] = field(default_factory=list)

    def __post_init__(self):
        """Calculate deltas."""
        # Duration
        if self.baseline.duration_ms > 0:
            self.duration_delta_pct = (
                (self.current.duration_ms - self.baseline.duration_ms)
                / self.baseline.duration_ms
                * 100
            )

        # Tokens
        if self.baseline.total_tokens > 0:
            self.tokens_delta_pct = (
                (self.current.total_tokens - self.baseline.total_tokens)
                / self.baseline.total_tokens
                * 100
            )

        # Counts
        self.model_calls_delta = self.current.model_calls - self.baseline.model_calls
        self.tool_calls_delta = self.current.tool_calls - self.baseline.tool_calls

        # Check for regression
        self._detect_regression()

    def _detect_regression(self) -> None:
        """Detect if this is a significant regression."""
        reasons = []

        if self.duration_delta_pct > 50:
            reasons.append(f"Duration increased {self.duration_delta_pct:.0f}%")

        if self.tokens_delta_pct > 50:
            reasons.append(f"Tokens increased {self.tokens_delta_pct:.0f}%")

        if self.model_calls_delta > 2:
            reasons.append(f"+{self.model_calls_delta} model calls")

        if self.current.failed_spans > self.baseline.failed_spans:
            delta = self.current.failed_spans - self.baseline.failed_spans
            reasons.append(f"+{delta} failed spans")

        self.regression_reasons = reasons
        self.is_regression = len(reasons) > 0


def compare_runs(state1: TraceState, state2: TraceState) -> RunComparison:
    """Compare two trace runs.

    Args:
        state1: Baseline (older) run
        state2: Current (newer) run

    Returns:
        RunComparison with deltas and regression detection
    """
    metrics1 = RunMetrics.from_state(state1)
    metrics2 = RunMetrics.from_state(state2)
    return RunComparison(baseline=metrics1, current=metrics2)


# ═══════════════════════════════════════════════════════════════════════════════
# Outlier Detection
# ═══════════════════════════════════════════════════════════════════════════════


@dataclass
class Outlier:
    """A detected outlier/anomaly in a trace."""

    kind: str  # "loop", "bloat", "retry", "latency"
    severity: str  # "info", "warning", "critical"
    message: str
    span_id: str | None = None
    details: dict[str, Any] = field(default_factory=dict)

    @property
    def icon(self) -> str:
        if self.kind == "loop":
            return "🔄"
        elif self.kind == "bloat":
            return "📈"
        elif self.kind == "retry":
            return "🔁"
        elif self.kind == "latency":
            return "⏱️"
        else:
            return "⚠️"


@dataclass
class OutlierReport:
    """Collection of detected outliers."""

    trace_id: str
    outliers: list[Outlier] = field(default_factory=list)

    @property
    def has_critical(self) -> bool:
        return any(o.severity == "critical" for o in self.outliers)

    @property
    def has_warnings(self) -> bool:
        return any(o.severity == "warning" for o in self.outliers)

    def by_severity(self, severity: str) -> list[Outlier]:
        return [o for o in self.outliers if o.severity == severity]


def detect_outliers(
    state: TraceState,
    loop_threshold: int = 3,
    bloat_threshold: float = 0.5,
    retry_threshold: int = 2,
    latency_multiplier: float = 2.0,
) -> OutlierReport:
    """Detect outliers and anomalies in a trace.

    Args:
        state: Trace state to analyze
        loop_threshold: Flag if same tool called more than this
        bloat_threshold: Flag if history > this fraction of input
        retry_threshold: Flag if more than this many retries
        latency_multiplier: Flag spans taking >this * average

    Returns:
        OutlierReport with detected issues
    """
    report = OutlierReport(trace_id=state.trace_id)

    # Collect spans by type for analysis
    tool_calls: dict[str, list[SpanState]] = {}
    durations: list[float] = []

    for span in state.spans.values():
        if span.kind == NodeKind.TOOL_CALL and span.name:
            tool_calls.setdefault(span.name, []).append(span)
        if span.duration_ms:
            durations.append(span.duration_ms)

    avg_duration = sum(durations) / len(durations) if durations else 0

    # 1. Loop detection (same tool called repeatedly)
    for tool_name, calls in tool_calls.items():
        if len(calls) > loop_threshold:
            report.outliers.append(
                Outlier(
                    kind="loop",
                    severity="warning"
                    if len(calls) <= loop_threshold * 2
                    else "critical",
                    message=f"Tool '{tool_name}' called {len(calls)} times",
                    details={"tool": tool_name, "count": len(calls)},
                )
            )

    # 2. Context bloat detection
    total_input = state.total_input_tokens
    # Estimate history tokens (this is approximate without full event data)
    history_estimate = sum(
        s.usage.input_tokens
        for s in state.spans.values()
        if s.kind == NodeKind.MODEL_CALL and s.parent_span_id
    )

    if total_input > 0 and history_estimate / total_input > bloat_threshold:
        pct = history_estimate / total_input * 100
        report.outliers.append(
            Outlier(
                kind="bloat",
                severity="warning" if pct < 70 else "critical",
                message=f"History context is {pct:.0f}% of input",
                details={
                    "history_tokens": history_estimate,
                    "total_input": total_input,
                },
            )
        )

    # 3. Latency spike detection
    if avg_duration > 0:
        for span in state.spans.values():
            if (
                span.duration_ms
                and span.duration_ms > avg_duration * latency_multiplier
            ):
                ratio = span.duration_ms / avg_duration
                report.outliers.append(
                    Outlier(
                        kind="latency",
                        severity="info" if ratio < 3 else "warning",
                        message=f"'{span.name or span.kind.value}' took {span.duration_ms:.0f}ms ({ratio:.1f}x avg)",
                        span_id=span.span_id,
                        details={
                            "duration_ms": span.duration_ms,
                            "avg_ms": avg_duration,
                        },
                    )
                )

    # 4. Failed span detection
    failed = [s for s in state.spans.values() if s.status == "failed"]
    if failed:
        report.outliers.append(
            Outlier(
                kind="retry",
                severity="warning" if len(failed) <= retry_threshold else "critical",
                message=f"{len(failed)} failed span(s)",
                details={"failed_spans": [s.span_id for s in failed]},
            )
        )

    return report


# ═══════════════════════════════════════════════════════════════════════════════
# Export Formats
# ═══════════════════════════════════════════════════════════════════════════════


def export_json(state: TraceState, events: list[TraceEvent]) -> dict[str, Any]:
    """Export trace as JSON structure."""
    return {
        "trace_id": state.trace_id,
        "created_at": state.created_at,
        "metrics": {
            "total_input_tokens": state.total_input_tokens,
            "total_output_tokens": state.total_output_tokens,
            "total_cost_usd": state.total_cost_usd,
            "span_count": len(state.spans),
        },
        "spans": [
            {
                "span_id": s.span_id,
                "node_id": s.node_id,
                "kind": s.kind.value,
                "name": s.name,
                "status": s.status,
                "parent_span_id": s.parent_span_id,
                "started_at": s.started_at,
                "ended_at": s.ended_at,
                "duration_ms": s.duration_ms,
                "usage": {
                    "input_tokens": s.usage.input_tokens,
                    "output_tokens": s.usage.output_tokens,
                    "reasoning_tokens": s.usage.reasoning_tokens,
                    "accounting": s.usage.accounting.value,
                },
            }
            for s in state.spans.values()
        ],
        "events": [e.to_dict() for e in events],
    }


def export_otel(state: TraceState, events: list[TraceEvent]) -> dict[str, Any]:
    """Export trace in OpenTelemetry-compatible format.

    Follows OTEL GenAI semantic conventions where applicable.
    """
    spans = []

    for span in state.spans.values():
        otel_span = {
            "traceId": state.trace_id,
            "spanId": span.span_id,
            "parentSpanId": span.parent_span_id,
            "name": f"{span.kind.value}.{span.name}" if span.name else span.kind.value,
            "kind": "SPAN_KIND_INTERNAL",
            "startTimeUnixNano": int(span.started_at * 1e9),
            "endTimeUnixNano": int((span.ended_at or span.started_at) * 1e9),
            "status": {
                "code": "STATUS_CODE_OK"
                if span.status == "done"
                else "STATUS_CODE_ERROR",
            },
            "attributes": [],
        }

        # Add GenAI attributes for model calls
        if span.kind == NodeKind.MODEL_CALL:
            otel_span["attributes"].extend(
                [
                    {"key": "gen_ai.system", "value": {"stringValue": "anthropic"}},
                    {
                        "key": "gen_ai.request.model",
                        "value": {"stringValue": span.name or "unknown"},
                    },
                    {
                        "key": "gen_ai.usage.input_tokens",
                        "value": {"intValue": span.usage.input_tokens},
                    },
                    {
                        "key": "gen_ai.usage.output_tokens",
                        "value": {"intValue": span.usage.output_tokens},
                    },
                ]
            )

        # Add tool attributes
        if span.kind == NodeKind.TOOL_CALL:
            otel_span["attributes"].extend(
                [
                    {
                        "key": "tool.name",
                        "value": {"stringValue": span.name or "unknown"},
                    },
                    {
                        "key": "tool.duration_ms",
                        "value": {"doubleValue": span.duration_ms or 0},
                    },
                ]
            )

        spans.append(otel_span)

    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": "code-puppy"}},
                        {"key": "service.version", "value": {"stringValue": "0.1.0"}},
                    ]
                },
                "scopeSpans": [
                    {
                        "scope": {"name": "agent_trace"},
                        "spans": spans,
                    }
                ],
            }
        ]
    }


def export_csv(state: TraceState) -> str:
    """Export trace as CSV."""
    lines = [
        "span_id,kind,name,status,parent_span_id,duration_ms,input_tokens,output_tokens"
    ]

    for span in state.spans.values():
        lines.append(
            ",".join(
                [
                    span.span_id,
                    span.kind.value,
                    span.name or "",
                    span.status,
                    span.parent_span_id or "",
                    str(span.duration_ms or ""),
                    str(span.usage.input_tokens),
                    str(span.usage.output_tokens),
                ]
            )
        )

    return "\n".join(lines)
