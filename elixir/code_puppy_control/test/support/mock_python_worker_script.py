#!/usr/bin/env python3
"""
Mock Python worker for E2E testing.

Note (ADR-005): This script is a bridge-compatibility test artifact for the
explicit PUP_RUNTIME=python / --bridge-mode compatibility path. It is NOT part
of the default daily-driver runtime. The Python-free runtime guarantee (v0.1.x)
is validated separately in python_free_runtime_test.exs. See ADR-005.

This script simulates the behavior of the real Python worker
without requiring the full Python stack. It:

1. Reads JSON-RPC requests from stdin using Content-Length framing
2. Responds with appropriate JSON-RPC responses
3. Sends notifications to simulate real agent behavior
4. Handles run lifecycle commands

Usage:
    python mock_python_worker_script.py

Or via Elixir Port:
    Port.open({:spawn, "python3 mock_python_worker_script.py"}, [:binary])
"""

import json
import sys
import threading
import time
from typing import Any, Dict, Optional


def read_message() -> Optional[Dict[str, Any]]:
    """
    Read a JSON-RPC message from stdin using Content-Length framing.

    Returns:
        Parsed message dict or None if EOF/error
    """
    try:
        # Read Content-Length header
        line = sys.stdin.readline()
        if not line:
            return None

        if not line.startswith("Content-Length:"):
            # Try to recover by reading next line
            return read_message()

        length_str = line.split(":", 1)[1].strip()
        try:
            length = int(length_str)
        except ValueError:
            print(f"Invalid Content-Length: {length_str}", file=sys.stderr)
            return None

        # Read empty separator line
        separator = sys.stdin.readline()
        if separator.strip() != "":
            # Malformed message, try to recover
            pass

        # Read the JSON body
        body = sys.stdin.read(length)
        if len(body) < length:
            # Incomplete message
            return None

        return json.loads(body)

    except json.JSONDecodeError as e:
        print(f"JSON decode error: {e}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error reading message: {e}", file=sys.stderr)
        return None


def write_message(msg: Dict[str, Any]) -> None:
    """
    Write a JSON-RPC message to stdout with Content-Length framing.

    Args:
        msg: The message dict to send
    """
    body = json.dumps(msg, separators=(",", ":"))
    framed = f"Content-Length: {len(body)}\r\n\r\n{body}"
    sys.stdout.write(framed)
    sys.stdout.flush()


def send_notification(method: str, params: Dict[str, Any]) -> None:
    """
    Send a JSON-RPC notification (no response expected).

    Args:
        method: The notification method name
        params: The notification parameters
    """
    notification = {"jsonrpc": "2.0", "method": method, "params": params}
    write_message(notification)


def send_response(result: Any, msg_id: Any) -> None:
    """
    Send a JSON-RPC success response.

    Args:
        result: The result data
        msg_id: The request ID to respond to
    """
    response = {"jsonrpc": "2.0", "id": msg_id, "result": result}
    write_message(response)


def send_error(code: int, message: str, msg_id: Any, data: Any = None) -> None:
    """
    Send a JSON-RPC error response.

    Args:
        code: Error code
        message: Error message
        msg_id: The request ID
        data: Optional additional error data
    """
    error = {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": code, "message": message},
    }
    if data is not None:
        error["error"]["data"] = data
    write_message(error)


def simulate_run_progress(run_id: str, session_id: str, duration: float = 2.0) -> None:
    """
    Simulate a run progressing through states in a background thread.

    Args:
        run_id: The run identifier
        session_id: The session identifier
        duration: How long to simulate the run taking
    """

    def progress_thread():
        # Small delay to ensure response is sent first
        time.sleep(0.1)

        # Send starting status
        send_notification(
            "run.status",
            {
                "run_id": run_id,
                "session_id": session_id,
                "status": "starting",
                "progress": 0.0,
            },
        )

        time.sleep(0.2)

        # Send running status
        send_notification(
            "run.status",
            {
                "run_id": run_id,
                "session_id": session_id,
                "status": "running",
                "progress": 0.5,
            },
        )

        # Simulate some work time
        time.sleep(duration)

        # Send completed status
        send_notification(
            "run.completed",
            {
                "run_id": run_id,
                "session_id": session_id,
                "status": "completed",
                "progress": 1.0,
                "result": "mock_execution_success",
            },
        )

    thread = threading.Thread(target=progress_thread, daemon=True)
    thread.start()


def handle_ping(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle ping/health check requests."""
    send_response({"status": "ok", "timestamp": int(time.time() * 1000)}, msg_id)


def handle_initialize(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle initialize requests."""
    send_response(
        {
            "status": "initialized",
            "capabilities": {
                "mock": True,
                "streaming": True,
                "tools": ["echo", "sleep", "mock_tool"],
            },
            "version": "mock-1.0.0",
        },
        msg_id,
    )


def handle_run_start(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle run.start requests."""
    run_id = params.get("run_id", "unknown")
    session_id = params.get("session_id", "unknown")
    config = params.get("config", {})
    prompt = config.get("prompt", "")

    # Acknowledge the run start
    send_response(
        {
            "run_id": run_id,
            "status": "accepted",
            "agent": params.get("agent_name", "unknown"),
        },
        msg_id,
    )

    # Check if we should simulate fast completion or longer run
    if "sleep" in prompt.lower():
        # Simulate a longer running task
        simulate_run_progress(run_id, session_id, duration=5.0)
    else:
        # Fast completion
        simulate_run_progress(run_id, session_id, duration=0.5)


def handle_run_cancel(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle run.cancel requests."""
    run_id = params.get("run_id", "unknown")

    send_response(
        {
            "run_id": run_id,
            "status": "cancelled",
            "cancelled_at": int(time.time() * 1000),
        },
        msg_id,
    )

    # Send cancellation notification
    send_notification(
        "run.status",
        {"run_id": run_id, "status": "cancelled", "reason": "user_request"},
    )


def handle_echo(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle echo test requests."""
    send_response({"echo": params, "timestamp": int(time.time() * 1000)}, msg_id)


def handle_shutdown(params: Dict[str, Any], msg_id: Any) -> None:
    """Handle shutdown requests."""
    send_response({"status": "shutting_down"}, msg_id)
    time.sleep(0.1)  # Give response time to send
    sys.exit(0)


def dispatch_request(msg: Dict[str, Any]) -> bool:
    """
    Dispatch a JSON-RPC request to the appropriate handler.

    Args:
        msg: The parsed JSON-RPC message

    Returns:
        True if the message was handled, False if we should stop
    """
    method = msg.get("method", "")
    params = msg.get("params", {})
    msg_id = msg.get("id")  # May be None for notifications

    # Route to handler based on method
    handlers = {
        "ping": handle_ping,
        "initialize": handle_initialize,
        "run.start": handle_run_start,
        "run.cancel": handle_run_cancel,
        "echo": handle_echo,
        "shutdown": handle_shutdown,
    }

    handler = handlers.get(method)

    if handler:
        try:
            handler(params, msg_id)
        except Exception as e:
            print(f"Handler error: {e}", file=sys.stderr)
            if msg_id is not None:
                send_error(-32603, f"Internal error: {e}", msg_id)
    elif msg_id is not None:
        # Unknown method - return error for requests (not notifications)
        send_error(-32601, f"Method not found: {method}", msg_id)
    else:
        # Unknown notification - just log
        print(f"Unknown notification: {method}", file=sys.stderr)

    # Check for shutdown
    return method != "shutdown"


def main():
    """Main entry point for the mock worker."""
    print("Mock Python Worker started", file=sys.stderr)
    print("Waiting for JSON-RPC messages on stdin...", file=sys.stderr)

    # Send startup notification
    send_notification(
        "system.ready",
        {"status": "ready", "capabilities": {"mock": True, "version": "1.0.0"}},
    )

    running = True
    while running:
        msg = read_message()
        if msg is None:
            # EOF or error - exit gracefully
            print("EOF received, exiting", file=sys.stderr)
            break

        running = dispatch_request(msg)

    print("Mock Python Worker exiting", file=sys.stderr)


if __name__ == "__main__":
    main()
