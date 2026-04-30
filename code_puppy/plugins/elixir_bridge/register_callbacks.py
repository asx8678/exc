"""Elixir Bridge Plugin - Registers callbacks for bridge mode operation.

This module registers callbacks when CODE_PUPPY_BRIDGE=1 is set, enabling
Python to be controlled by Elixir via JSON-RPC over stdio.

Implements BRIDGE_PROTOCOL_V1 with canonical method names:
- run.status, run.text, run.tool_result, run.completed, run.failed, run.prompt
- bridge.ready, bridge.closing

Callbacks registered:
- startup: Initialize bridge and start stdin reader
- shutdown: Cleanup bridge resources
- stream_event: Emit events to stdout in canonical JSON-RPC format

See: docs/protocol/BRIDGE_PROTOCOL_V1.md for full specification.
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
from typing import Any

from code_puppy.callbacks import register_callback
from code_puppy.plugins.elixir_bridge import BRIDGE_ENABLED, BRIDGE_LOG_FILE

# Import the bridge components
from .bridge_controller import BridgeController
from .wire_protocol import (
    to_canonical_notification,
    emit_bridge_ready,
    emit_bridge_closing,
)

# Module-level logger
logger = logging.getLogger(__name__)

# Module-level state - bridge controller instance and stdin reader task
_bridge_controller: BridgeController | None = None
_stdin_reader_task: asyncio.Task[None] | None = None


def _log_bridge(message: str, level: str = "info") -> None:
    """Log bridge activity to file if BRIDGE_LOG_FILE is set."""
    if BRIDGE_LOG_FILE:
        try:
            with open(BRIDGE_LOG_FILE, "a") as f:
                f.write(f"[{level}] {message}\n")
        except Exception:
            pass  # Best effort logging


def _write_framed_message(msg: dict) -> None:
    """Write a JSON-RPC message with Content-Length framing.

    Per BRIDGE_PROTOCOL_V1, only Content-Length framing is supported.
    Newline-delimited JSON has been removed from the protocol.

    Format: Content-Length: <N>\r\n\r\n<json-body>
    """
    try:
        body = json.dumps(msg, separators=(",", ":"))
        body_bytes = body.encode("utf-8")
        header = f"Content-Length: {len(body_bytes)}\r\n\r\n"
        sys.stdout.buffer.write(header.encode("utf-8"))
        sys.stdout.buffer.write(body_bytes)
        sys.stdout.buffer.flush()
    except Exception as e:
        _log_bridge(f"Failed to write framed message: {e}", "error")


def _request_bridge_stop(reason: str) -> None:
    """Mark the active bridge controller stopped so bridge mode can exit."""
    if _bridge_controller is None:
        return

    _bridge_controller.request_stop()
    _log_bridge(f"Bridge controller stop requested: {reason}", "info")


async def _read_framed_message(reader: asyncio.StreamReader) -> dict | None:
    """Read a JSON-RPC message with Content-Length framing from reader.

    Per BRIDGE_PROTOCOL_V1, only Content-Length framing is supported.
    Newline-delimited JSON has been removed from the protocol.

    Returns None on EOF or parse error.
    """
    try:
        # Read header line (Content-Length: N\r\n).
        # StreamReader methods are async; treating their coroutine return values
        # like bytes breaks Content-Length framing, so always await them.
        try:
            header = await reader.readuntil(b"\r\n")
        except asyncio.IncompleteReadError as e:
            if e.partial:
                _log_bridge(f"Incomplete header read: {e.partial!r}", "error")
            return None
        except asyncio.LimitOverrunError as e:
            _log_bridge(f"Header too long while reading frame: {e}", "error")
            return None

        # Parse Content-Length
        header_str = header.decode("utf-8").strip()
        if not header_str.lower().startswith("content-length:"):
            _log_bridge(f"Invalid header: {header_str[:50]}", "error")
            return None

        try:
            content_length = int(header_str.split(":", 1)[1].strip())
        except ValueError, IndexError:
            _log_bridge(f"Failed to parse Content-Length from: {header_str}", "error")
            return None

        if content_length < 0:
            _log_bridge(f"Invalid negative Content-Length: {content_length}", "error")
            return None

        # Read separator \r\n.
        try:
            separator = await reader.readexactly(2)
        except asyncio.IncompleteReadError as e:
            _log_bridge(
                f"Incomplete separator read: got {len(e.partial)} bytes, expected 2",
                "error",
            )
            return None

        if separator != b"\r\n":
            _log_bridge(f"Invalid separator: {separator!r}", "error")
            return None

        # Read exactly content_length bytes.
        try:
            body_bytes = await reader.readexactly(content_length)
        except asyncio.IncompleteReadError as e:
            _log_bridge(
                f"Incomplete read: got {len(e.partial)} bytes, expected {content_length}",
                "error",
            )
            return None

        return json.loads(body_bytes.decode("utf-8"))
    except json.JSONDecodeError as e:
        _log_bridge(f"JSON parse error: {e}", "error")
        return None
    except UnicodeDecodeError as e:
        _log_bridge(f"UTF-8 decode error: {e}", "error")
        return None
    except Exception as e:
        _log_bridge(f"Read error: {e}", "error")
        return None


async def _on_startup() -> None:
    """Initialize the Elixir bridge on startup.

    Called when CODE_PUPPY_BRIDGE=1 is set. Sets up:
    1. Bridge controller for command dispatch
    2. Stdin reader for receiving JSON-RPC commands
    3. Event redirection to stdout with canonical methods

    Async-safe: Uses non-blocking I/O only (asyncio, not blocking stdin).
    """
    global _bridge_controller, _stdin_reader_task

    if not BRIDGE_ENABLED:
        return

    _log_bridge("Initializing Elixir bridge mode", "info")

    try:
        # Create bridge controller - handles command dispatch
        _bridge_controller = BridgeController()

        # Emit bridge.ready notification (canonical V1 method name)
        notification = emit_bridge_ready(
            capabilities=["invoke_agent", "run_shell", "file_ops", "event_stream"],
            version="1.0.0",
        )
        _write_framed_message(notification)

        # Start stdin reader in background task
        # Async-safe: Uses asyncio.StreamReader, not blocking stdlib input()
        _stdin_reader_task = asyncio.create_task(
            _stdin_reader_loop(), name="code-puppy-bridge-stdin-reader"
        )

        _log_bridge("Bridge ready - awaiting commands from stdin", "info")

    except Exception as e:
        _log_bridge(f"Bridge initialization failed: {e}", "error")
        logger.error(f"Elixir bridge initialization failed: {e}")
        raise


async def _on_shutdown() -> None:
    """Cleanup bridge resources on shutdown.

    Async-safe: Cancels pending tasks, closes resources without blocking.
    """
    global _bridge_controller, _stdin_reader_task

    if not BRIDGE_ENABLED:
        return

    controller = _bridge_controller
    reader_task = _stdin_reader_task
    if controller is None and reader_task is None:
        return

    _log_bridge("Shutting down Elixir bridge", "info")

    try:
        # Emit bridge.closing notification (canonical V1 method name)
        if controller is not None:
            notification = emit_bridge_closing(reason="shutdown")
            _write_framed_message(notification)

        # Stop the background stdin reader before dropping controller state.
        if reader_task is not None:
            if not reader_task.done():
                reader_task.cancel()
            try:
                await reader_task
            except asyncio.CancelledError:
                pass
            except Exception as e:
                _log_bridge(f"Stdin reader shutdown error: {e}", "error")
            finally:
                _stdin_reader_task = None

        # Cleanup bridge controller
        if controller is not None:
            await controller.shutdown()
            if _bridge_controller is controller:
                _bridge_controller = None

        _log_bridge("Bridge shutdown complete", "info")

    except Exception as e:
        _log_bridge(f"Bridge shutdown error: {e}", "error")
        logger.error(f"Elixir bridge shutdown error: {e}")


def _on_stream_event(
    event_type: str, event_data: dict[str, Any], agent_session_id: str | None = None
) -> None:
    """Emit event to stdout in canonical JSON-RPC format.

    This callback intercepts all events and forwards them to Elixir
    via stdout using canonical BRIDGE_PROTOCOL_V1 notification methods:
    - run.status, run.text, run.tool_result
    - run.completed, run.failed, run.prompt
    - run.event (generic fallback)

    Uses Content-Length framing per BRIDGE_PROTOCOL_V1.

    Args:
        event_type: Type of event (e.g., "tool_call", "agent_response")
        event_data: Event-specific data (includes run_id, payload, etc.)
        agent_session_id: Optional session identifier
    """
    if not BRIDGE_ENABLED:
        return

    try:
        # Extract run_id from event data
        run_id = event_data.get("run_id", "")

        # Extract payload from event data (support both payload key and flat structure)
        payload = event_data.get("payload", event_data)

        # Map internal event type to canonical method
        notification = to_canonical_notification(
            event_type=event_type,
            run_id=run_id,
            session_id=agent_session_id,
            payload=payload,
        )

        # Write to stdout with Content-Length framing
        _write_framed_message(notification)

        _log_bridge(f"Emitted canonical event: {notification['method']}", "debug")

    except Exception as e:
        _log_bridge(f"Failed to emit event: {e}", "error")
        # Don't raise - event emission should not break agent flow


async def _stdin_reader_loop() -> None:
    """Read JSON-RPC commands from stdin.

    Continuously reads Content-Length framed JSON commands from stdin,
    dispatches them via the bridge controller, and writes responses.

    Per BRIDGE_PROTOCOL_V1, only Content-Length framing is supported.
    Newline-delimited JSON has been removed from the protocol.

    Async-safe: Uses asyncio.StreamReader for non-blocking I/O.
    See: docs/rules/async-io.md for callback implementation rules.
    """
    if _bridge_controller is None:
        return

    _log_bridge("Starting stdin reader loop", "info")
    stop_reason = "stdin reader stopped"

    try:
        # Get asyncio-compatible stdin reader
        # Async-safe: Uses asyncio.StreamReader, not blocking sys.stdin
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        protocol = asyncio.StreamReaderProtocol(reader)

        try:
            await loop.connect_read_pipe(lambda: protocol, sys.stdin)
        except Exception as e:
            stop_reason = "stdin pipe attach failed"
            _log_bridge(f"Failed to connect stdin pipe: {e}", "error")
            return

        while (
            BRIDGE_ENABLED
            and _bridge_controller is not None
            and _bridge_controller.running
        ):
            try:
                # Read framed message using BRIDGE_PROTOCOL_V1 Content-Length framing.
                request = await _read_framed_message(reader)

                if request is None:
                    # EOF or parse error - reader is exhausted
                    stop_reason = "stdin EOF"
                    _log_bridge("Stdin EOF reached", "info")
                    break

                _log_bridge(f"Received: {str(request)[:200]}...", "debug")

                # Validate basic JSON-RPC structure
                if request.get("jsonrpc") != "2.0":
                    _send_jsonrpc_error(
                        request.get("id"),
                        -32600,
                        "Invalid Request: expected jsonrpc 2.0",
                    )
                    continue

                # Detect responses to OUR requests (reverse channel)
                # Responses have "result" or "error" but no "method"
                if (
                    "result" in request or "error" in request
                ) and "method" not in request:
                    from code_puppy.plugins.elixir_bridge import handle_response

                    handle_response(request)
                    _log_bridge(
                        f"Handled reverse-channel response id={request.get('id')}",
                        "debug",
                    )
                    continue

                controller = _bridge_controller
                if controller is None:
                    stop_reason = "bridge controller removed"
                    break

                # Dispatch command
                response = await controller.dispatch(request)

                # Send response if request has an id (not a notification)
                if "id" in request and response is not None:
                    _send_jsonrpc_response(request["id"], response)

            except asyncio.CancelledError:
                stop_reason = "stdin reader cancelled"
                _log_bridge("Stdin reader cancelled", "info")
                break
            except Exception as e:
                _log_bridge(f"Stdin reader error: {e}", "error")
                _send_jsonrpc_error(None, -32603, f"Internal error: {e}")
    finally:
        _request_bridge_stop(stop_reason)


def _send_jsonrpc_response(request_id: Any, result: Any) -> None:
    """Send a JSON-RPC success response.

    Uses Content-Length framing for Elixir protocol compatibility.
    """
    try:
        response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        _write_framed_message(response)
    except Exception as e:
        _log_bridge(f"Failed to send response: {e}", "error")


def _send_jsonrpc_error(
    request_id: Any, code: int, message: str, data: Any = None
) -> None:
    """Send a JSON-RPC error response.

    Uses Content-Length framing for Elixir protocol compatibility.
    """
    try:
        error = {"code": code, "message": message}
        if data is not None:
            error["data"] = data

        response = {"jsonrpc": "2.0", "id": request_id, "error": error}
        _write_framed_message(response)
    except Exception as e:
        _log_bridge(f"Failed to send error: {e}", "error")


# =============================================================================
# Callback Registration
# =============================================================================

# Register callbacks only if bridge mode is enabled
if BRIDGE_ENABLED:
    register_callback("startup", _on_startup)
    register_callback("shutdown", _on_shutdown)
    register_callback("stream_event", _on_stream_event)

    _log_bridge("Elixir bridge callbacks registered", "info")
