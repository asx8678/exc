"""Agent Trace V2 — Normalized Event Schema.

Based on agent_flow_v2_schema_example.json. This module defines:
- Event types for spans, transfers, and usage
- Node kinds: user, agent_run, model_call, tool_call, etc.
- Transfer kinds: model_input, model_output, tool_args, tool_result, etc.
- Token classes with accounting state (estimated vs exact)
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any


class NodeKind(str, Enum):
    """Types of nodes in the execution graph."""

    USER = "user"
    SESSION = "session"
    AGENT_RUN = "agent_run"
    MODEL_CALL = "model_call"
    TOOL_CALL = "tool_call"
    MEMORY_SNAPSHOT = "memory_snapshot"
    ARTIFACT = "artifact"


class TransferKind(str, Enum):
    """Types of token/data transfers between nodes."""

    USER_PROMPT = "user_prompt"
    SYSTEM_INSTRUCTIONS = "system_instructions"
    HISTORY_CONTEXT = "history_context"
    RETRIEVED_CONTEXT = "retrieved_context"
    MODEL_INPUT = "model_input"
    MODEL_OUTPUT = "model_output"
    TOOL_ARGS = "tool_args"
    TOOL_RESULT = "tool_result"
    DELEGATE_PROMPT = "delegate_prompt"
    DELEGATE_RESPONSE = "delegate_response"
    MEMORY_APPEND = "memory_append"
    ARTIFACT_WRITE = "artifact_write"
    ARTIFACT_READ = "artifact_read"


class TokenClass(str, Enum):
    """Categories of tokens for accounting."""

    INPUT_TOKENS = "input_tokens"
    OUTPUT_TOKENS = "output_tokens"
    REASONING_TOKENS = "reasoning_tokens"
    CACHED_TOKENS = "cached_tokens"
    ESTIMATED_TOKENS = "estimated_tokens"
    BILLABLE_TOKENS = "billable_tokens"


class AccountingState(str, Enum):
    """Confidence level of token counts.

    This is the key insight from V2: separate what we know for sure
    from what we're estimating live.
    """

    ESTIMATED_LIVE = "estimated_live"  # Calculated from stream chunks
    PROVIDER_REPORTED_EXACT = "provider_reported_exact"  # From API usage response
    RECONCILED = "reconciled"  # Estimate corrected by exact value
    UNKNOWN = "unknown"  # No information available


class EventType(str, Enum):
    """Types of trace events."""

    SPAN_STARTED = "span.started"
    SPAN_UPDATED = "span.updated"
    SPAN_ENDED = "span.ended"
    TRANSFER_STARTED = "transfer.started"
    TRANSFER_CHUNK = "transfer.chunk"
    TRANSFER_COMPLETED = "transfer.completed"
    USAGE_REPORTED = "usage.reported"
    USAGE_RECONCILED = "usage.reconciled"
    ARTIFACT_CREATED = "artifact.created"
    ARTIFACT_READ = "artifact.read"


@dataclass
class NodeInfo:
    """Information about a node in the execution graph."""

    id: str
    kind: NodeKind
    name: str | None = None
    status: str | None = None
    parent_node_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind.value,
            "name": self.name,
            "status": self.status,
            "parent_node_id": self.parent_node_id,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> NodeInfo:
        return cls(
            id=data["id"],
            kind=NodeKind(data["kind"]),
            name=data.get("name"),
            status=data.get("status"),
            parent_node_id=data.get("parent_node_id"),
        )


@dataclass
class TransferInfo:
    """Information about a token/data transfer between nodes."""

    kind: TransferKind
    source_node_id: str | None = None
    target_node_id: str | None = None
    message_id: str | None = None
    token_count: int | None = None
    token_class: TokenClass | None = None
    accounting: AccountingState = AccountingState.UNKNOWN
    preview: str | None = None  # Truncated/redacted content preview

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind.value,
            "source_node_id": self.source_node_id,
            "target_node_id": self.target_node_id,
            "message_id": self.message_id,
            "token_count": self.token_count,
            "token_class": self.token_class.value if self.token_class else None,
            "accounting": self.accounting.value,
            "preview": self.preview,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> TransferInfo:
        return cls(
            kind=TransferKind(data["kind"]),
            source_node_id=data.get("source_node_id"),
            target_node_id=data.get("target_node_id"),
            message_id=data.get("message_id"),
            token_count=data.get("token_count"),
            token_class=TokenClass(data["token_class"])
            if data.get("token_class")
            else None,
            accounting=AccountingState(data.get("accounting", "unknown")),
            preview=data.get("preview"),
        )


@dataclass
class MetricsInfo:
    """Timing and cost metrics for a span or transfer."""

    duration_ms: float | None = None
    cost_usd: float | None = None
    queue_time_ms: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "duration_ms": self.duration_ms,
            "cost_usd": self.cost_usd,
            "queue_time_ms": self.queue_time_ms,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MetricsInfo:
        return cls(
            duration_ms=data.get("duration_ms"),
            cost_usd=data.get("cost_usd"),
            queue_time_ms=data.get("queue_time_ms"),
        )


def _generate_id() -> str:
    """Generate a unique event ID."""
    return str(uuid.uuid4())


def _now_iso() -> str:
    """Get current UTC timestamp in ISO format."""
    return datetime.now(timezone.utc).isoformat()


@dataclass
class TraceEvent:
    """A normalized trace event.

    This is the core data structure for Agent Flow V2. Every observation
    about agent execution is represented as a TraceEvent.
    """

    event_id: str = field(default_factory=_generate_id)
    trace_id: str = ""  # Root session/run identifier
    event_type: EventType = EventType.SPAN_STARTED
    timestamp: str = field(default_factory=_now_iso)

    # Optional identifiers for correlation
    span_id: str | None = None
    parent_span_id: str | None = None
    run_id: str | None = None
    session_id: str | None = None

    # Structured data
    node: NodeInfo | None = None
    transfer: TransferInfo | None = None
    metrics: MetricsInfo | None = None

    # Extension point for additional data
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Serialize to dictionary for JSON output."""
        result = {
            "event_id": self.event_id,
            "trace_id": self.trace_id,
            "event_type": self.event_type.value,
            "timestamp": self.timestamp,
        }

        if self.span_id:
            result["span_id"] = self.span_id
        if self.parent_span_id:
            result["parent_span_id"] = self.parent_span_id
        if self.run_id:
            result["run_id"] = self.run_id
        if self.session_id:
            result["session_id"] = self.session_id
        if self.node:
            result["node"] = self.node.to_dict()
        if self.transfer:
            result["transfer"] = self.transfer.to_dict()
        if self.metrics:
            result["metrics"] = self.metrics.to_dict()
        if self.extra:
            result["extra"] = self.extra

        return result

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> TraceEvent:
        """Deserialize from dictionary."""
        return cls(
            event_id=data["event_id"],
            trace_id=data["trace_id"],
            event_type=EventType(data["event_type"]),
            timestamp=data["timestamp"],
            span_id=data.get("span_id"),
            parent_span_id=data.get("parent_span_id"),
            run_id=data.get("run_id"),
            session_id=data.get("session_id"),
            node=NodeInfo.from_dict(data["node"]) if data.get("node") else None,
            transfer=TransferInfo.from_dict(data["transfer"])
            if data.get("transfer")
            else None,
            metrics=MetricsInfo.from_dict(data["metrics"])
            if data.get("metrics")
            else None,
            extra=data.get("extra", {}),
        )

    def to_json(self) -> str:
        """Serialize to JSON string."""
        import json

        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, json_str: str) -> TraceEvent:
        """Deserialize from JSON string."""
        import json

        return cls.from_dict(json.loads(json_str))
