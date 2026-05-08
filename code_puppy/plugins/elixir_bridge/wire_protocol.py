"""Wire Protocol - Serialization for Elixir communication.

Translates between Python message types and Elixir wire protocol format using
canonical BRIDGE_PROTOCOL_V1 methods.

Canonical Wire Protocol Format (V1):
```json
// Status update
{"jsonrpc":"2.0","method":"run.status","params":{"run_id":"...","status":"running"}}

// Text output
{"jsonrpc":"2.0","method":"run.text","params":{"run_id":"...","text":"..."}}

// Tool result
{"jsonrpc":"2.0","method":"run.tool_result","params":{"run_id":"...","tool_name":"..."}}

// Bridge lifecycle
{"jsonrpc":"2.0","method":"bridge.ready","params":{"version":"1.0.0"}}
```

See: docs/protocol/BRIDGE_PROTOCOL_V1.md for full specification.

Protocol bridge optimization
- orjson support for faster serialization (5-10x improvement)
- Batch message framing support
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

# Optional orjson support for faster serialization
try:
    import orjson

    _HAS_ORJSON = True
except ImportError:
    _HAS_ORJSON = False


class WireMethodError(Exception):
    """Error in wire protocol method dispatch."""

    def __init__(self, message: str, code: int = -32600):
        self.code = code
        super().__init__(message)


# Backwards compatibility alias for tests
JsonRpcError = WireMethodError

# JSON-RPC 2.0 error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
SERVER_ERROR_MIN = -32000
SERVER_ERROR_MAX = -32099

# Legacy constant names (for backwards compatibility)
JSONRPC_PARSE_ERROR = PARSE_ERROR
JSONRPC_INVALID_REQUEST = INVALID_REQUEST
JSONRPC_METHOD_NOT_FOUND = METHOD_NOT_FOUND
JSONRPC_INVALID_PARAMS = INVALID_PARAMS
JSONRPC_INTERNAL_ERROR = INTERNAL_ERROR
JSONRPC_SERVER_ERROR_MIN = SERVER_ERROR_MIN
JSONRPC_SERVER_ERROR_MAX = SERVER_ERROR_MAX


def _get_timestamp() -> str:
    """Generate ISO 8601 timestamp."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Serialization helpers for orjson optimization
def _serialize_json(data: Any) -> bytes:
    """Serialize data to JSON bytes, using orjson if available.

    orjson is 5-10x faster than stdlib json for serialization.
    Falls back to stdlib json if orjson is not installed.
    """
    if _HAS_ORJSON:
        return orjson.dumps(data)
    return json.dumps(data, separators=(",", ":")).encode("utf-8")


def _deserialize_json(data: bytes) -> Any:
    """Deserialize JSON bytes, using orjson if available.

    orjson is 5-10x faster than stdlib json for deserialization.
    Falls back to stdlib json if orjson is not installed.
    """
    if _HAS_ORJSON:
        return orjson.loads(data)
    return json.loads(data.decode("utf-8"))


def emit_run_status(
    run_id: str,
    session_id: str | None,
    status: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.status notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        status: Status value (initializing, running, paused, cancelling, completed, failed)
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "status": status,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id

    return {
        "jsonrpc": "2.0",
        "method": "run.status",
        "params": params,
    }


def emit_run_text(
    run_id: str,
    session_id: str | None,
    text: str,
    finished: bool = False,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.text notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        text: Text content
        finished: Whether this is the final text chunk
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "text": text,
        "finished": finished,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id

    return {
        "jsonrpc": "2.0",
        "method": "run.text",
        "params": params,
    }


def emit_run_tool_result(
    run_id: str,
    session_id: str | None,
    tool_call_id: str,
    tool_name: str,
    result: dict[str, Any],
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.tool_result notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        tool_call_id: Tool call correlation ID
        tool_name: Name of the tool that was executed
        result: Tool execution result dict
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "tool_call_id": tool_call_id,
        "tool_name": tool_name,
        "result": result,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id

    return {
        "jsonrpc": "2.0",
        "method": "run.tool_result",
        "params": params,
    }


def emit_run_completed(
    run_id: str,
    session_id: str | None,
    result: dict[str, Any] | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.completed notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        result: Optional run result data
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id
    if result is not None:
        params["result"] = result

    return {
        "jsonrpc": "2.0",
        "method": "run.completed",
        "params": params,
    }


def emit_run_failed(
    run_id: str,
    session_id: str | None,
    error_code: int,
    error_message: str,
    error_details: dict[str, Any] | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.failed notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        error_code: Error code (see BRIDGE_PROTOCOL_V1.md)
        error_message: Human-readable error message
        error_details: Optional additional error context
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    error: dict[str, Any] = {
        "code": error_code,
        "message": error_message,
    }
    if error_details is not None:
        error["details"] = error_details

    params: dict[str, Any] = {
        "run_id": run_id,
        "error": error,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id

    return {
        "jsonrpc": "2.0",
        "method": "run.failed",
        "params": params,
    }


def emit_run_prompt(
    run_id: str,
    session_id: str | None,
    prompt_id: str,
    question: str,
    options: list[str] | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.prompt notification.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        prompt_id: Prompt correlation ID
        question: The prompt question text
        options: Optional list of options for the user to choose from
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "prompt_id": prompt_id,
        "question": question,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id
    if options is not None:
        params["options"] = options

    return {
        "jsonrpc": "2.0",
        "method": "run.prompt",
        "params": params,
    }


def emit_run_event(
    run_id: str,
    session_id: str | None,
    event_type: str,
    data: dict[str, Any],
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run.event notification (generic events).

    Used for events that don't have a specific canonical method.

    Args:
        run_id: Run identifier
        session_id: Optional session identifier
        event_type: Internal event type identifier
        data: Event-specific data
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    params: dict[str, Any] = {
        "run_id": run_id,
        "event_type": event_type,
        "data": data,
        "timestamp": timestamp or _get_timestamp(),
    }
    if session_id is not None:
        params["session_id"] = session_id

    return {
        "jsonrpc": "2.0",
        "method": "run.event",
        "params": params,
    }


def emit_bridge_ready(
    capabilities: list[str],
    version: str = "1.0.0",
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit bridge.ready notification.

    Args:
        capabilities: List of bridge capabilities
        version: Bridge protocol version
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "bridge.ready",
        "params": {
            "capabilities": capabilities,
            "version": version,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_bridge_closing(
    reason: str = "shutdown",
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit bridge.closing notification.

    Args:
        reason: Reason for bridge closing
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "bridge.closing",
        "params": {
            "reason": reason,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_concurrency_acquire(
    limiter_type: str,
    timeout: float | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit concurrency.acquire request.

    Args:
        limiter_type: Type of limiter (file_ops, api_calls, tool_calls)
        timeout: Optional timeout in seconds
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    params: dict[str, Any] = {
        "type": limiter_type,
        "timestamp": timestamp or _get_timestamp(),
    }
    if timeout is not None:
        params["timeout"] = timeout

    return {
        "jsonrpc": "2.0",
        "method": "concurrency.acquire",
        "params": params,
    }


def emit_concurrency_release(
    limiter_type: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit concurrency.release notification.

    Args:
        limiter_type: Type of limiter (file_ops, api_calls, tool_calls)
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "concurrency.release",
        "params": {
            "type": limiter_type,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_concurrency_status(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit concurrency.status request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "concurrency.status",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_run_limiter_acquire(
    timeout: float | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run_limiter.acquire request.

    Args:
        timeout: Optional timeout in seconds
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    params: dict[str, Any] = {
        "timestamp": timestamp or _get_timestamp(),
    }
    if timeout is not None:
        params["timeout"] = timeout

    return {
        "jsonrpc": "2.0",
        "method": "run_limiter.acquire",
        "params": params,
    }


def emit_run_limiter_release(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run_limiter.release notification.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "run_limiter.release",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_run_limiter_status(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run_limiter.status request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "run_limiter.status",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_run_limiter_set_limit(
    limit: int,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit run_limiter.set_limit request.

    Args:
        limit: New concurrency limit value
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "run_limiter.set_limit",
        "params": {
            "limit": limit,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_mcp_register_server(
    name: str,
    command: str,
    args: list[str],
    env: dict[str, str] | None = None,
    opts: dict[str, Any] | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.register request.

    Args:
        name: Server name identifier
        command: Command to execute (e.g., "npx")
        args: Command arguments as list
        env: Optional environment variables dict
        opts: Optional additional server configuration
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    params: dict[str, Any] = {
        "name": name,
        "command": command,
        "args": args,
        "timestamp": timestamp or _get_timestamp(),
    }
    if env is not None:
        params["env"] = env
    if opts is not None:
        params["opts"] = opts

    return {
        "jsonrpc": "2.0",
        "method": "mcp.register",
        "params": params,
    }


def emit_mcp_unregister_server(
    server_id: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.unregister request.

    Args:
        server_id: Server identifier to unregister
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "mcp.unregister",
        "params": {
            "server_id": server_id,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_mcp_list_servers(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.list request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "mcp.list",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_mcp_get_status(
    server_id: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.status request.

    Args:
        server_id: Server identifier to get status for
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "mcp.status",
        "params": {
            "server_id": server_id,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_mcp_call_tool(
    server_id: str,
    method: str,
    params: dict[str, Any],
    timeout: float = 30.0,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.call_tool request.

    Args:
        server_id: Server identifier
        method: Tool method name to call
        params: Tool parameters dict
        timeout: Maximum seconds to wait for response
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "mcp.call_tool",
        "params": {
            "server_id": server_id,
            "method": method,
            "params": params,
            "timeout": timeout,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_mcp_health_check(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit mcp.health_check request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "mcp.health_check",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_eventbus_broadcast(
    topic: str,
    event_type: str,
    payload: dict[str, Any],
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit eventbus.broadcast notification.

    Args:
        topic: EventBus topic (e.g., "session:<id>", "run:<id>", "global:events")
        event_type: Event type identifier
        payload: Event data payload
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC notification dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "eventbus.broadcast",
        "params": {
            "topic": topic,
            "event_type": event_type,
            "payload": payload,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_eventbus_subscribe(
    topic: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit eventbus.subscribe request.

    Args:
        topic: EventBus topic to subscribe to
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "eventbus.subscribe",
        "params": {
            "topic": topic,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_eventbus_unsubscribe(
    topic: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit eventbus.unsubscribe request.

    Args:
        topic: EventBus topic to unsubscribe from
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "eventbus.unsubscribe",
        "params": {
            "topic": topic,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


# ── Rate Limiter Wire Protocol ─────────────────────────────────────


def emit_rate_limiter_record_limit(
    model_name: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit rate_limiter.record_limit request.

    Args:
        model_name: The model name that received a 429 response
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "rate_limiter.record_limit",
        "params": {
            "model_name": model_name,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_rate_limiter_record_success(
    model_name: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit rate_limiter.record_success request.

    Args:
        model_name: The model name that had a successful request
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "rate_limiter.record_success",
        "params": {
            "model_name": model_name,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_rate_limiter_get_limit(
    model_name: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit rate_limiter.get_limit request.

    Args:
        model_name: The model name to get limit for
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "rate_limiter.get_limit",
        "params": {
            "model_name": model_name,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_rate_limiter_circuit_status(
    model_name: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit rate_limiter.circuit_status request.

    Args:
        model_name: The model name to get circuit status for
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "rate_limiter.circuit_status",
        "params": {
            "model_name": model_name,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


# ── Agent Manager Wire Protocol ────────────────────────────────────


def emit_agent_manager_register(
    agent_name: str,
    agent_info: dict[str, Any],
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit agent_manager.register request.

    Args:
        agent_name: The name of the agent to register
        agent_info: Agent metadata (display_name, description, etc.)
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "agent_manager.register",
        "params": {
            "agent_name": agent_name,
            "agent_info": agent_info,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_agent_manager_list(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit agent_manager.list request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "agent_manager.list",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_agent_manager_get_current(
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit agent_manager.get_current request.

    Args:
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "agent_manager.get_current",
        "params": {
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def emit_agent_manager_set_current(
    agent_name: str,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Emit agent_manager.set_current request.

    Args:
        agent_name: The name of the agent to set as current
        timestamp: Optional timestamp (auto-generated if None)

    Returns:
        JSON-RPC request dict
    """
    return {
        "jsonrpc": "2.0",
        "method": "agent_manager.set_current",
        "params": {
            "agent_name": agent_name,
            "timestamp": timestamp or _get_timestamp(),
        },
    }


def to_canonical_notification(
    event_type: str,
    run_id: str | None,
    session_id: str | None,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Map internal event type to canonical notification method.

    Translates internal event types to BRIDGE_PROTOCOL_V1 canonical methods:
    - status -> run.status
    - text -> run.text
    - tool_output -> run.tool_result
    - completed -> run.completed
    - failed -> run.failed
    - prompt -> run.prompt
    - other -> run.event

    Args:
        event_type: Internal event type identifier
        run_id: Optional run identifier
        session_id: Optional session identifier
        payload: Event-specific data dict

    Returns:
        JSON-RPC notification dict with canonical method name

    Example:
        >>> notification = to_canonical_notification(
        ... event_type="tool_output",
        ... run_id="run-123",
        ... session_id="sess-456",
        ... payload={"tool_name": "file_read", "result": {...}}
        ... )
        >>> print(notification["method"]) # "run.tool_result"
    """
    payload = payload or {}

    # Map internal event types to canonical methods
    if event_type == "status":
        return emit_run_status(
            run_id=run_id or "",
            session_id=session_id,
            status=payload.get("status", "unknown"),
        )
    elif event_type == "text":
        return emit_run_text(
            run_id=run_id or "",
            session_id=session_id,
            text=payload.get("text", ""),
            finished=payload.get("finished", False),
        )
    elif event_type == "tool_output":
        return emit_run_tool_result(
            run_id=run_id or "",
            session_id=session_id,
            tool_call_id=payload.get("tool_call_id", ""),
            tool_name=payload.get("tool_name", ""),
            result=payload.get("result", {}),
        )
    elif event_type == "completed":
        return emit_run_completed(
            run_id=run_id or "",
            session_id=session_id,
            result=payload.get("result"),
        )
    elif event_type == "failed":
        return emit_run_failed(
            run_id=run_id or "",
            session_id=session_id,
            error_code=payload.get("error_code", -32000),
            error_message=payload.get("error_message", "Unknown error"),
            error_details=payload.get("error_details"),
        )
    elif event_type == "prompt":
        return emit_run_prompt(
            run_id=run_id or "",
            session_id=session_id,
            prompt_id=payload.get("prompt_id", ""),
            question=payload.get("question", ""),
            options=payload.get("options"),
        )
    else:
        # Generic event for unrecognized types
        return emit_run_event(
            run_id=run_id or "",
            session_id=session_id,
            event_type=event_type,
            data=payload,
        )


def from_wire_params(method: str, params: dict[str, Any]) -> dict[str, Any]:
    """Validate and normalize wire protocol params for a method.

    Supports both dot-style (V1) and slash-style (legacy) method names.
    Per BRIDGE_PROTOCOL_V1, dot-style is preferred.

    Args:
        method: Method name being called (e.g., "run.start", "run.cancel")
        params: Raw params from JSON-RPC request

    Returns:
        Validated and normalized params dict

    Raises:
        WireMethodError: If params are invalid
    """
    # Normalize slash-style to dot-style for compatibility
    normalized_method = method.replace("/", ".")

    # V1 canonical methods (dot-style)
    if normalized_method == "run.start":
        if "agent_name" not in params:
            raise WireMethodError(
                "run.start requires 'agent_name' param", INVALID_PARAMS
            )
        # code_puppy-mmk.4: Accept prompt at top-level or nested under config
        # Elixir AgentInvocation.invoke passes prompt inside config map
        prompt = params.get("prompt")
        if prompt is None:
            config = params.get("config", {})
            if isinstance(config, dict):
                prompt = config.get("prompt")
        if not prompt:
            raise WireMethodError(
                "run.start requires 'prompt' (top-level or under config)",
                INVALID_PARAMS,
            )
        result = {
            "agent_name": str(params["agent_name"]),
            "prompt": str(prompt),
            "session_id": params.get("session_id"),
            "context": params.get("context", {}),
        }
        # Only include run_id if provided - handler will auto-generate if missing
        if "run_id" in params:
            result["run_id"] = params["run_id"]
        # Preserve config for downstream consumption (e.g. is_new_session)
        if "config" in params and isinstance(params["config"], dict):
            result["config"] = params["config"]
        return result

    elif normalized_method == "run.cancel":
        if "run_id" not in params:
            raise WireMethodError("run.cancel requires 'run_id' param", INVALID_PARAMS)
        return {
            "run_id": str(params["run_id"]),
            "reason": params.get("reason", "user_requested"),
        }

    elif normalized_method == "initialize":
        return {
            "capabilities": params.get("capabilities", []),
            "config": params.get("config", {}),
        }

    elif normalized_method == "exit":
        return {
            "reason": params.get("reason", "shutdown"),
            "timeout_ms": int(params.get("timeout_ms", 5000)),
        }

    # Legacy methods (kept for backward compatibility during transition)
    elif normalized_method == "invoke_agent":
        if "agent_name" not in params:
            raise WireMethodError(
                "invoke_agent requires 'agent_name' param", INVALID_PARAMS
            )
        if "prompt" not in params:
            raise WireMethodError(
                "invoke_agent requires 'prompt' param", INVALID_PARAMS
            )
        result = {
            "agent_name": str(params["agent_name"]),
            "prompt": str(params["prompt"]),
            "session_id": params.get("session_id"),
        }
        # Only include run_id if provided - handler will auto-generate if missing
        if "run_id" in params:
            result["run_id"] = params["run_id"]
        return result

    elif normalized_method == "run_shell":
        if "command" not in params:
            raise WireMethodError("run_shell requires 'command' param", INVALID_PARAMS)
        return {
            "command": str(params["command"]),
            "cwd": params.get("cwd"),
            "timeout": int(params.get("timeout", 60)),
        }

    elif normalized_method == "file_list":
        if "directory" not in params:
            raise WireMethodError(
                "file_list requires 'directory' param", INVALID_PARAMS
            )
        return {
            "directory": str(params["directory"]),
            "recursive": bool(params.get("recursive", False)),
        }

    elif normalized_method == "file_read":
        if "path" not in params:
            raise WireMethodError("file_read requires 'path' param", INVALID_PARAMS)
        return {
            "path": str(params["path"]),
            "start_line": params.get("start_line"),
            "num_lines": params.get("num_lines"),
        }

    elif normalized_method == "file_write":
        if "path" not in params:
            raise WireMethodError("file_write requires 'path' param", INVALID_PARAMS)
        if "content" not in params:
            raise WireMethodError("file_write requires 'content' param", INVALID_PARAMS)
        return {
            "path": str(params["path"]),
            "content": str(params["content"]),
        }

    elif normalized_method == "grep_search":
        if "search_string" not in params:
            raise WireMethodError(
                "grep_search requires 'search_string' param", INVALID_PARAMS
            )
        return {
            "search_string": str(params["search_string"]),
            "directory": str(params.get("directory", ".")),
        }

    # Batch file read support
    elif normalized_method == "file_read_batch":
        if "paths" not in params:
            raise WireMethodError(
                "file_read_batch requires 'paths' param", INVALID_PARAMS
            )
        return {
            "paths": list(params["paths"]),
            "start_line": params.get("start_line"),
            "num_lines": params.get("num_lines"),
        }

    # Concurrency control methods
    elif normalized_method == "concurrency.acquire":
        limiter_type = params.get("type", "file_ops")
        if limiter_type not in ("file_ops", "api_calls", "tool_calls"):
            raise WireMethodError(
                f"Invalid limiter type: {limiter_type}. Must be one of: file_ops, api_calls, tool_calls",
                INVALID_PARAMS,
            )
        result: dict[str, Any] = {"type": limiter_type}
        if "timeout" in params:
            result["timeout"] = float(params["timeout"])
        return result

    elif normalized_method == "concurrency.release":
        limiter_type = params.get("type", "file_ops")
        if limiter_type not in ("file_ops", "api_calls", "tool_calls"):
            raise WireMethodError(
                f"Invalid limiter type: {limiter_type}. Must be one of: file_ops, api_calls, tool_calls",
                INVALID_PARAMS,
            )
        return {"type": limiter_type}

    elif normalized_method == "concurrency.status":
        return {}  # No params needed for status

    # Run limiter methods
    elif normalized_method == "run_limiter.acquire":
        result: dict[str, Any] = {}
        if "timeout" in params:
            result["timeout"] = float(params["timeout"])
        return result

    elif normalized_method == "run_limiter.release":
        return {}  # No params needed for release

    elif normalized_method == "run_limiter.status":
        return {}  # No params needed for status

    elif normalized_method == "run_limiter.set_limit":
        if "limit" not in params:
            raise WireMethodError(
                "run_limiter.set_limit requires 'limit' param", INVALID_PARAMS
            )
        limit = int(params["limit"])
        if limit < 1:
            raise WireMethodError("limit must be >= 1", INVALID_PARAMS)
        return {"limit": limit}

    # MCP bridge methods
    elif normalized_method == "mcp.register":
        if "name" not in params:
            raise WireMethodError("mcp.register requires 'name' param", INVALID_PARAMS)
        if "command" not in params:
            raise WireMethodError(
                "mcp.register requires 'command' param", INVALID_PARAMS
            )
        if "args" not in params:
            raise WireMethodError("mcp.register requires 'args' param", INVALID_PARAMS)
        result: dict[str, Any] = {
            "name": str(params["name"]),
            "command": str(params["command"]),
            "args": list(params["args"]),
        }
        if "env" in params:
            result["env"] = dict(params["env"])
        if "opts" in params:
            result["opts"] = dict(params["opts"])
        return result

    elif normalized_method == "mcp.unregister":
        if "server_id" not in params:
            raise WireMethodError(
                "mcp.unregister requires 'server_id' param", INVALID_PARAMS
            )
        return {"server_id": str(params["server_id"])}

    elif normalized_method == "mcp.list":
        return {}  # No params needed for list

    elif normalized_method == "mcp.status":
        if "server_id" not in params:
            raise WireMethodError(
                "mcp.status requires 'server_id' param", INVALID_PARAMS
            )
        return {"server_id": str(params["server_id"])}

    elif normalized_method == "mcp.call_tool":
        if "server_id" not in params:
            raise WireMethodError(
                "mcp.call_tool requires 'server_id' param", INVALID_PARAMS
            )
        if "method" not in params:
            raise WireMethodError(
                "mcp.call_tool requires 'method' param", INVALID_PARAMS
            )
        result = {
            "server_id": str(params["server_id"]),
            "method": str(params["method"]),
            "params": dict(params.get("params", {})),
        }
        if "timeout" in params:
            result["timeout"] = float(params["timeout"])
        return result

    elif normalized_method == "mcp.health_check":
        return {}  # No params needed for health_check

    # EventBus bridge methods
    elif normalized_method == "eventbus.event":
        if "topic" not in params:
            raise WireMethodError(
                "eventbus.event requires 'topic' param", INVALID_PARAMS
            )
        result: dict[str, Any] = {
            "topic": str(params["topic"]),
            "event_type": str(params.get("event_type", "")),
            "payload": dict(params.get("payload", {})),
        }
        if "timestamp" in params:
            result["timestamp"] = str(params["timestamp"])
        return result

    elif normalized_method in ("get_status", "ping"):
        return params

    # Rate limiter methods
    elif normalized_method == "rate_limiter.record_limit":
        if "model_name" not in params:
            raise WireMethodError(
                "rate_limiter.record_limit requires 'model_name' param", INVALID_PARAMS
            )
        return {"model_name": str(params["model_name"])}

    elif normalized_method == "rate_limiter.record_success":
        if "model_name" not in params:
            raise WireMethodError(
                "rate_limiter.record_success requires 'model_name' param",
                INVALID_PARAMS,
            )
        return {"model_name": str(params["model_name"])}

    elif normalized_method == "rate_limiter.get_limit":
        if "model_name" not in params:
            raise WireMethodError(
                "rate_limiter.get_limit requires 'model_name' param", INVALID_PARAMS
            )
        return {"model_name": str(params["model_name"])}

    elif normalized_method == "rate_limiter.circuit_status":
        if "model_name" not in params:
            raise WireMethodError(
                "rate_limiter.circuit_status requires 'model_name' param",
                INVALID_PARAMS,
            )
        return {"model_name": str(params["model_name"])}

    # Agent manager methods
    elif normalized_method == "agent_manager.register":
        if "agent_name" not in params:
            raise WireMethodError(
                "agent_manager.register requires 'agent_name' param", INVALID_PARAMS
            )
        result: dict[str, Any] = {
            "agent_name": str(params["agent_name"]),
            "agent_info": dict(params.get("agent_info", {})),
        }
        return result

    elif normalized_method == "agent_manager.list":
        return {}  # No params needed for list

    elif normalized_method == "agent_manager.get_current":
        return {}  # No params needed for get_current

    elif normalized_method == "agent_manager.set_current":
        if "agent_name" not in params:
            raise WireMethodError(
                "agent_manager.set_current requires 'agent_name' param", INVALID_PARAMS
            )
        return {"agent_name": str(params["agent_name"])}

    # Model packs methods
    elif normalized_method == "model_packs.get_pack":
        return {"name": str(params.get("name", ""))} if params else {}

    elif normalized_method == "model_packs.list_packs":
        return {}  # No params needed

    elif normalized_method == "model_packs.set_current_pack":
        if "name" not in params:
            raise WireMethodError(
                "model_packs.set_current_pack requires 'name' param", INVALID_PARAMS
            )
        return {"name": str(params["name"])}

    elif normalized_method == "model_packs.get_current_pack":
        return {}  # No params needed

    elif normalized_method == "model_packs.get_model_for_role":
        return {"role": str(params.get("role", ""))} if params else {}

    elif normalized_method == "model_packs.get_fallback_chain":
        return {"role": str(params.get("role", ""))} if params else {}

    elif normalized_method == "model_packs.create_pack":
        if "name" not in params:
            raise WireMethodError(
                "model_packs.create_pack requires 'name' param", INVALID_PARAMS
            )
        if "description" not in params:
            raise WireMethodError(
                "model_packs.create_pack requires 'description' param", INVALID_PARAMS
            )
        result: dict[str, Any] = {
            "name": str(params["name"]),
            "description": str(params["description"]),
            "roles": dict(params.get("roles", {})),
            "default_role": str(params.get("default_role", "coder")),
        }
        return result

    elif normalized_method == "model_packs.delete_pack":
        if "name" not in params:
            raise WireMethodError(
                "model_packs.delete_pack requires 'name' param", INVALID_PARAMS
            )
        return {"name": str(params["name"])}

    elif normalized_method == "model_packs.reload":
        return {}  # No params needed

    else:
        raise WireMethodError(f"Unknown method: {method}", METHOD_NOT_FOUND)


def frame_message(message: dict[str, Any]) -> bytes:
    """Frame a message with Content-Length header for wire transmission.

    Uses HTTP-style Content-Length framing as per BRIDGE_PROTOCOL.md:
    Content-Length: <byte-length>\\r\\n

    \\r\\n

    <json-body>

    Uses orjson for faster serialization when available.

    Args:
        message: Message dict to frame

    Returns:
        Framed message as bytes ready for stdio

    Example:
        >>> message = {"jsonrpc": "2.0", "method": "ping", "params": {}}
        >>> framed = frame_message(message)
        >>> print(framed)
        b'Content-Length: 49\\r\\n\\r\\n{"jsonrpc":"2.0","method":"ping","params":{}}'
    """
    body = _serialize_json(message)
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
    return header + body


def parse_framed_message(framed: bytes) -> dict[str, Any]:
    """Parse a Content-Length framed message.

    Parses HTTP-style Content-Length framing as per BRIDGE_PROTOCOL_V1.md:
    Content-Length: <byte-length>\\r\\n

    \\r\\n

    <json-body>

    Uses orjson for faster deserialization when available.

    Args:
        framed: Framed message bytes

    Returns:
        Parsed JSON message dict

    Raises:
        WireMethodError: If framing is invalid or JSON is malformed

    Example:
        >>> framed = b'Content-Length: 49\\r\\n\\r\\n{"jsonrpc":"2.0","method":"ping","params":{}}'
        >>> parsed = parse_framed_message(framed)
        >>> print(parsed["method"])
        'ping'
    """
    try:
        # Find the header/body separator
        if b"\r\n\r\n" not in framed:
            raise WireMethodError(
                "Invalid framing: missing header/body separator", PARSE_ERROR
            )

        header_part, body = framed.split(b"\r\n\r\n", 1)

        # Parse Content-Length header
        if not header_part.startswith(b"Content-Length: "):
            raise WireMethodError(
                "Invalid framing: missing Content-Length header", PARSE_ERROR
            )

        try:
            content_length = int(header_part.split(b": ")[1])
        except (IndexError, ValueError) as e:
            raise WireMethodError(
                f"Invalid Content-Length value: {e}", PARSE_ERROR
            ) from e

        # Validate body length
        if len(body) != content_length:
            raise WireMethodError(
                f"Content-Length mismatch: expected {content_length}, got {len(body)}",
                PARSE_ERROR,
            )

        # Parse JSON body using orjson if available
        try:
            return _deserialize_json(body)
        except (json.JSONDecodeError, Exception) as e:
            raise WireMethodError(
                f"Invalid JSON in message body: {e}", PARSE_ERROR
            ) from e

    except WireMethodError:
        raise
    except Exception as e:
        raise WireMethodError(
            f"Failed to parse framed message: {e}", PARSE_ERROR
        ) from e


def serialize_for_wire(data: Any) -> str:
    """Serialize data to JSON string for wire protocol.

    Uses compact formatting (no whitespace) for efficiency.
    Uses orjson for faster serialization when available.

    Args:
        data: Data to serialize

    Returns:
        JSON string
    """
    if _HAS_ORJSON:
        return orjson.dumps(data).decode("utf-8")
    return json.dumps(data, separators=(",", ":"), default=_json_default)


def _json_default(obj: Any) -> Any:
    """JSON serializer for special types."""
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, set):
        return list(obj)
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")
