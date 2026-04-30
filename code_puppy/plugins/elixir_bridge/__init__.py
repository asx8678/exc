"""Elixir Bridge Plugin - Bridge mode for Elixir Port communication.

This plugin enables Code Puppy to run as a child process controlled by Elixir
via JSON-RPC over stdio. When CODE_PUPPY_BRIDGE=1 environment variable is set,
the bridge activates and:

1. Emits events to stdout in JSON-RPC format
2. Receives commands from stdin in JSON-RPC format
3. Translates between Python message types and Elixir wire protocol

This prepares Python to be controlled by Elixir for the migration.

Environment:
    CODE_PUPPY_BRIDGE=1 Enable bridge mode
    CODE_PUPPY_BRIDGE_LOG Optional log file path for debugging

Example Elixir Port usage:
    # Elixir side
    port = Port.open({:spawn, "python -m code_puppy"}, [:binary, :exit_status])
    # Send command
    Port.command(port, ~s({"jsonrpc": "2.0", "id": "1", "method": "invoke_agent", "params": {...}}\n))
    # Receive event
    receive do
      {^port, {:data, data}} ->
        # data contains JSON-RPC notification
    end

Architecture:
    ┌─────────────┐ stdio (JSON-RPC) ┌─────────────┐
    │ Elixir │ ───────────────────────────▶│ Python │
    │ (Port) │◀───────────────────────────────│ (Bridge) │
    └─────────────┘ └─────────────┘
                                                          │
                            ┌──────────────────────────────┘
                            ▼
                    ┌─────────────────┐
                    │ Agent Tools │
                    │ File Ops │
                    │ Shell Commands │
                    └─────────────────┘

See: docs/architecture/python-singleton-audit.md for migration context.

Client mode for calling Elixir control plane from Python
- Added is_connected() to check if Elixir control plane is available
- Added call_method() to send JSON-RPC requests to Elixir
- Used by NativeBackend to route file operations through Elixir

Concurrency control bridge support
- Added call_elixir_concurrency() for semaphore coordination

MCP bridge support
- Added call_elixir_mcp() for MCP server management via bridge

Protocol bridge optimization
- Replace polling with threading.Event for response matching
- Add orjson support for faster serialization (5-10x improvement)
- Add batch request support (N requests in single frame)
"""

from __future__ import annotations

import asyncio
import os
import threading
import time
import uuid
from typing import Any

from .wire_protocol import _serialize_json

# Bridge mode detection - used by register_callbacks to decide whether to activate
BRIDGE_ENABLED = os.environ.get("CODE_PUPPY_BRIDGE", "").strip() == "1"
BRIDGE_LOG_FILE = os.environ.get("CODE_PUPPY_BRIDGE_LOG")

# Client mode: Python calling Elixir control plane
# These are set when Elixir control plane is detected
_elixir_control_plane_url: str | None = None


# Response slot with threading.Event for zero-latency notification
class _ResponseSlot:
    """Response slot with threading.Event for instant notification.

    Replaces polling-based response matching with event-driven approach.
    Eliminates the 10ms polling floor that was adding latency.
    """

    __slots__ = ("event", "result", "error", "_lock")

    def __init__(self):
        self.event = threading.Event()
        self.result: Any = None
        self.error: Any = None
        self._lock = threading.Lock()

    def wait(self, timeout: float) -> tuple[Any, Any]:
        """Wait for response with timeout. Returns (result, error)."""
        if self.event.wait(timeout):
            return self.result, self.error
        return None, None  # Timeout

    def complete(self, result: Any, error: Any) -> None:
        """Mark response as complete."""
        with self._lock:
            self.result = result
            self.error = error
            self.event.set()


_pending_responses: dict[str, _ResponseSlot] = {}
_response_lock = threading.Lock()


def is_connected() -> bool:
    """Check if Elixir control plane is connected and available.

    Returns:
        True if Elixir control plane is available for JSON-RPC calls.
    """
    global _elixir_control_plane_url

    # Check environment variable for control plane URL
    if _elixir_control_plane_url is None:
        env_url = os.environ.get("CODE_PUPPY_ELIXIR_URL")
        if env_url:
            _elixir_control_plane_url = env_url

    # For now, connection is established via environment variable
    # Future: Add socket/HTTP discovery mechanism
    return _elixir_control_plane_url is not None


def set_connection_url(url: str | None) -> None:
    """Set the Elixir control plane connection URL.

    Args:
        url: URL for the Elixir control plane (e.g., "http://localhost:4000/rpc"
             or unix socket path), or None to disconnect.
    """
    global _elixir_control_plane_url
    _elixir_control_plane_url = url


def get_connection_url() -> str | None:
    """Get the current Elixir control plane connection URL.

    Returns:
        The connection URL if set, None otherwise.
    """
    return _elixir_control_plane_url


async def await_shutdown() -> None:
    """Wait until bridge-mode shutdown is requested.

    Public wrapper used by application code that needs to keep the process alive
    while the Python bridge worker is active. The implementation lives in the
    callback-registration layer because that layer owns the bridge controller
    and stdin reader task.

    Raises:
        RuntimeError: If bridge callbacks did not activate.
    """
    from . import register_callbacks

    await register_callbacks.await_shutdown()


def call_method(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call a method on the Elixir control plane via JSON-RPC.

    Sends a JSON-RPC 2.0 request to the Elixir control plane and waits
    for the response. Used by NativeBackend to route file operations.

    Uses threading.Event for zero-latency response notification
    instead of polling with time.sleep().

    Args:
        method: JSON-RPC method name (e.g., "file_list", "file_read")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir

    Raises:
        ConnectionError: If Elixir control plane is not connected
        TimeoutError: If response not received within timeout
        RuntimeError: If the call returns an error response
    """
    global _elixir_control_plane_url, _pending_responses

    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    # Generate unique request ID
    request_id = f"req-{uuid.uuid4().hex[:16]}"

    # Build JSON-RPC request
    request = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params,
    }

    # Create response slot with threading.Event (optimization)
    slot = _ResponseSlot()
    with _response_lock:
        _pending_responses[request_id] = slot

    try:
        # Send the request
        send_request_to_elixir(request)

        # Wait using threading.Event instead of polling
        result, error = slot.wait(timeout)

        if result is None and error is None and not slot.event.is_set():
            raise TimeoutError(f"Elixir call timed out after {timeout}s")

        # Check for error response
        if error is not None:
            raise RuntimeError(f"Elixir call failed: {error}")

        return result if result is not None else {}

    finally:
        # Clean up response slot
        with _response_lock:
            _pending_responses.pop(request_id, None)


async def call_elixir_concurrency(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call a concurrency method on the Elixir control plane.

    Specialized wrapper around call_method for concurrency operations.
    Falls back to local execution on timeout/connection errors.

    Args:
        method: Concurrency method name (e.g., "concurrency.acquire")
        params: Method parameters dict (e.g., {"type": "file_ops"})
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_run_limiter(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call a run limiter method on the Elixir control plane.

    Specialized wrapper around call_method for run limiting operations.
    Used by RunLimiter to delegate counter operations to Elixir when connected.
    Falls back to local execution on timeout/connection errors.

    Args:
        method: Run limiter method name (e.g., "run_limiter.acquire")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_mcp(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call an MCP method on the Elixir control plane.

    Specialized wrapper around call_method for MCP server management operations.
    Used to delegate MCP server management to the Elixir control plane when available.

    Args:
        method: MCP method name (e.g., "mcp.list", "mcp.status")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or raises exception on failure

    Raises:
        ConnectionError: If Elixir control plane is not connected
        TimeoutError: If response not received within timeout
        RuntimeError: If the call returns an error response
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    # Call through to Elixir control plane
    return await asyncio.to_thread(call_method, method, params, timeout=timeout)


async def call_elixir_rate_limiter(
    method: str, params: dict[str, Any], timeout: float = 10.0
) -> dict[str, Any]:
    """Call a rate limiter method on the Elixir control plane.

    Specialized wrapper around call_method for adaptive rate limiting operations.
    Used to delegate rate limit coordination to the Elixir control plane when available.
    Falls back to local execution on timeout/connection errors.

    Args:
        method: Rate limiter method name (e.g., "rate_limiter.record_limit",
                "rate_limiter.record_success", "rate_limiter.get_limit",
                "rate_limiter.circuit_status")
        params: Method parameters dict (e.g., {"model_name": "gpt-4"})
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_agent_manager(
    method: str, params: dict[str, Any], timeout: float = 10.0
) -> dict[str, Any]:
    """Call an agent manager method on the Elixir control plane.

    Specialized wrapper around call_method for agent management operations.
    Used to delegate agent management to the Elixir control plane when available.
    Falls back to local execution on timeout/connection errors.

    Args:
        method: Agent manager method name (e.g., "agent_manager.register",
                "agent_manager.list", "agent_manager.get_current",
                "agent_manager.set_current")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_round_robin(
    method: str, params: dict[str, Any], timeout: float = 10.0
) -> dict[str, Any]:
    """Call a round-robin method on the Elixir control plane.

    Specialized wrapper around call_method for round-robin model rotation operations.
    Used to delegate model rotation state management to the Elixir control plane
    when available. Falls back to local execution on timeout/connection errors.

    Args:
        method: Round-robin method name (e.g., "round_robin.get_next",
                "round_robin.get_current", "round_robin.reset",
                "round_robin.get_state", "round_robin.configure")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_model_packs(
    method: str, params: dict[str, Any], timeout: float = 10.0
) -> dict[str, Any]:
    """Call a model packs method on the Elixir control plane.

    Specialized wrapper around call_method for model pack operations.
    Used to delegate model pack management to the Elixir control plane when available.
    Falls back to local execution on timeout/connection errors.

    Args:
        method: Model packs method name (e.g., "model_packs.get_pack",
                "model_packs.list_packs", "model_packs.set_current_pack",
                "model_packs.get_current_pack", "model_packs.get_model_for_role",
                "model_packs.get_fallback_chain", "model_packs.create_pack",
                "model_packs.delete_pack", "model_packs.reload")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected (not raised on timeout)
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_workflow(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call a workflow method on the Elixir control plane.

    Replaces DBOS workflow invocations with Oban-backed durable execution.
    Routes through the Elixir bridge when available, falls back to
    non-durable local execution on timeout/connection errors.

    Supported methods:
        - "workflow.invoke_agent": Start a durable agent invocation
        - "workflow.get_status": Get workflow status
        - "workflow.cancel": Cancel a running workflow
        - "workflow.list_recent": List recent workflows
        - "workflow.get_history": Get workflow step history

    Args:
        method: Workflow method name (e.g., "workflow.invoke_agent")
        params: Method parameters dict (must include workflow_id)
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


async def call_elixir_agent_tools(
    method: str, params: dict[str, Any], timeout: float = 30.0
) -> dict[str, Any]:
    """Call an agent_tools method on the Elixir control plane.

    Specialized wrapper for agent tool operations ported from
    agent_tools.py (Phase E: code_puppy-mmk.4). When the Elixir
    control plane is connected, routes agent invocation and listing
    through the Elixir AgentInvocation module. Falls back to local
    Python execution on timeout/connection errors.

    Supported methods:
        - "agent_tools.list": List available sub-agents
        - "agent_tools.invoke": Invoke a sub-agent with full session mgmt
        - "agent_tools.invoke_headless": Lightweight agent invocation for plugins
        - "agent_tools.generate_session_id": Generate a unique session ID

    Args:
        method: Agent tool method name (e.g., "agent_tools.invoke")
        params: Method parameters dict
        timeout: Maximum seconds to wait for response

    Returns:
        Response result dict from Elixir, or fallback result on timeout

    Raises:
        ConnectionError: If Elixir control plane is not connected
    """
    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    try:
        return await asyncio.to_thread(call_method, method, params, timeout=timeout)
    except TimeoutError:
        # Return a fallback result that signals local handling
        return {"status": "timeout", "fallback": True}


def send_request_to_elixir(request: dict[str, Any]) -> None:
    """Send a JSON-RPC request to the Elixir control plane.

    In bridge mode (CODE_PUPPY_BRIDGE=1), writes Content-Length
    framed JSON-RPC to stdout. Elixir port.ex already handles requests
    from Python and sends responses back via stdin.

    Uses orjson for faster serialization when available.

    When not in bridge mode, raises NotImplementedError.
    """
    if not BRIDGE_ENABLED:
        raise NotImplementedError(
            "Elixir control plane client transport not yet implemented "
            "outside bridge mode. NativeBackend will fall back to Python."
        )

    import sys

    try:
        body_bytes = _serialize_json(request)
        header = f"Content-Length: {len(body_bytes)}\r\n\r\n"
        sys.stdout.buffer.write(header.encode("utf-8"))
        sys.stdout.buffer.write(body_bytes)
        sys.stdout.buffer.flush()
    except Exception as e:
        raise ConnectionError(f"Failed to send request to Elixir: {e}") from e


def send_batch_to_elixir(requests: list[dict[str, Any]]) -> None:
    """Send multiple JSON-RPC requests in a single frame.

    Batching reduces IPC overhead by combining N requests into one write.
    Uses JSON-RPC 2.0 batch format (array of request objects).

    Args:
        requests: List of JSON-RPC request dicts
    """
    if not BRIDGE_ENABLED:
        raise NotImplementedError(
            "Elixir control plane client transport not yet implemented "
            "outside bridge mode."
        )

    import sys

    try:
        # JSON-RPC 2.0 batch format: array of messages
        body_bytes = _serialize_json(requests)
        header = f"Content-Length: {len(body_bytes)}\r\n\r\n"
        sys.stdout.buffer.write(header.encode("utf-8"))
        sys.stdout.buffer.write(body_bytes)
        sys.stdout.buffer.flush()
    except Exception as e:
        raise ConnectionError(f"Failed to send batch to Elixir: {e}") from e


def call_batch(
    calls: list[tuple[str, dict[str, Any]]], timeout: float = 30.0
) -> list[dict[str, Any]]:
    """Send multiple JSON-RPC calls as a batch.

    Batching reduces IPC overhead by combining N requests into a single
    write operation. Responses are matched by request ID.

    Args:
        calls: List of (method, params) tuples
        timeout: Maximum seconds to wait for all responses

    Returns:
        List of result dicts in same order as calls

    Raises:
        TimeoutError: If any response not received within timeout
        RuntimeError: If any call returns an error
    """
    global _pending_responses

    if not is_connected():
        raise ConnectionError("Elixir control plane not connected")

    # Build all requests and register response slots
    requests = []
    slots: list[tuple[str, _ResponseSlot]] = []

    for method, params in calls:
        request_id = f"req-{uuid.uuid4().hex[:16]}"
        slot = _ResponseSlot()

        requests.append(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )

        with _response_lock:
            _pending_responses[request_id] = slot

        slots.append((request_id, slot))

    try:
        # Send all requests in a single frame
        send_batch_to_elixir(requests)

        # Wait for all responses
        results = []
        deadline = time.time() + timeout

        for request_id, slot in slots:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("Batch call timed out")

            result, error = slot.wait(remaining)

            if result is None and error is None and not slot.event.is_set():
                raise TimeoutError(f"Batch call timed out waiting for {request_id}")

            if error is not None:
                raise RuntimeError(f"Elixir call failed: {error}")

            results.append(result if result is not None else {})

        return results

    finally:
        # Clean up all response slots
        with _response_lock:
            for request_id, _ in slots:
                _pending_responses.pop(request_id, None)


def handle_response(response: dict[str, Any]) -> None:
    """Handle a JSON-RPC response from Elixir.

    Called by the transport layer when a response is received from Elixir.

    Uses threading.Event for instant notification.

    Args:
        response: JSON-RPC response dict with "id", "result", and/or "error"
    """
    global _pending_responses

    request_id = response.get("id")
    if request_id is None:
        return  # Notification, no response needed

    with _response_lock:
        slot = _pending_responses.get(request_id)
        if slot is not None:
            slot.complete(response.get("result"), response.get("error"))


def notify_elixir_event(
    event_type: str,
    payload: dict[str, Any],
    run_id: str | None = None,
    session_id: str | None = None,
) -> None:
    """Notify Elixir EventBus of an event.

    Fire-and-forget notification to Elixir EventBus. This function:
    - Returns immediately without blocking
    - Silently ignores all errors (auxiliary, not critical path)
    - Uses thread-safe operations if needed
    - Sends event to appropriate topic based on run_id/session_id

    Args:
        event_type: Type of event (e.g., "agent_run_start", "tool_call", etc.)
        payload: Event data payload
        run_id: Optional run identifier (determines topic)
        session_id: Optional session identifier (included in payload)
    """
    # Determine topic based on scope
    if run_id:
        topic = f"run:{run_id}"
    elif session_id:
        topic = f"session:{session_id}"
    else:
        topic = "global:events"

    # Add session_id to payload if provided
    full_payload = dict(payload)
    if session_id is not None:
        full_payload["session_id"] = session_id

    try:
        # Build the JSON-RPC notification using wire protocol
        from .wire_protocol import emit_eventbus_broadcast

        message = emit_eventbus_broadcast(
            topic=topic,
            event_type=event_type,
            payload=full_payload,
        )

        # Send the message - use _send_request_to_elixir if available
        # This is fire-and-forget, we don't wait for response
        if BRIDGE_ENABLED:
            # In bridge mode, write directly to stdout with Content-Length framing
            send_request_to_elixir(message)
        elif is_connected():
            # Client mode - send async if we can, otherwise sync
            try:
                loop = asyncio.get_running_loop()
                # We're in async context, use call_soon_threadsafe if on different thread
                if threading.current_thread().ident != loop._thread_id:  # type: ignore[attr-defined]
                    loop.call_soon_threadsafe(send_request_to_elixir, message)
                else:
                    send_request_to_elixir(message)
            except RuntimeError:
                # No running loop, call directly (sync context)
                send_request_to_elixir(message)
        # else: not connected, silently drop

    except Exception:
        # Fire-and-forget: silently ignore all errors
        # This is auxiliary functionality, not critical path
        pass


__all__ = [
    "BRIDGE_ENABLED",
    "BRIDGE_LOG_FILE",
    # Client mode (Python -> Elixir)
    "is_connected",
    "set_connection_url",
    "get_connection_url",
    "call_method",
    "handle_response",
    # Bridge-mode lifecycle
    "await_shutdown",
    # Batch support
    "call_batch",
    "send_batch_to_elixir",
    # Concurrency bridge support
    "call_elixir_concurrency",
    # Run limiter bridge support
    "call_elixir_run_limiter",
    # MCP bridge support
    "call_elixir_mcp",
    # EventBus bridge support
    "notify_elixir_event",
    # Adaptive rate limiter bridge support
    "call_elixir_rate_limiter",
    # Agent manager bridge support
    "call_elixir_agent_manager",
    # Round-robin bridge support
    "call_elixir_round_robin",
    # Model packs bridge support
    "call_elixir_model_packs",
    # Workflow bridge support (DBOS replacement)
    "call_elixir_workflow",
    # Agent tools bridge support (Phase E: code_puppy-mmk.4)
    "call_elixir_agent_tools",
]
