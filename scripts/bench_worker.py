#!/usr/bin/env python3
"""
Benchmark Worker - Minimal JSON-RPC worker for Content-Length framed communication.

This worker reads JSON-RPC requests from stdin and writes responses to stdout
using Content-Length framing compatible with the Elixir Control Plane protocol.

Protocol Format:
    Content-Length: <bytes>\r\n
    \r\n
    {"jsonrpc":"2.0","id":1,"method":"echo","params":{"msg":"hello"}}

Supported Methods:
    - initialize: Initialize worker (returns capabilities)
    - echo: Echo back the params
    - sleep: Sleep for N seconds (params: {"duration": 0.1})
    - crash: Intentionally crash the worker

Usage:
    python bench_worker.py

    # Or with Elixir Port:
    Port.open({:spawn, "python3 bench_worker.py"}, [:binary])

Exit Codes:
    0 - Normal exit (after shutdown method or stdin EOF)
    1 - Unexpected error
    42 - Intentional crash (test fault recovery)
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any, Optional


class ExitCode(IntEnum):
    """Exit codes for the worker."""

    NORMAL = 0
    ERROR = 1
    INTENTIONAL_CRASH = 42


@dataclass
class WorkerStats:
    """Statistics for the worker session."""

    requests_handled: int = 0
    start_time_ns: int = field(default_factory=lambda: time.perf_counter_ns())

    @property
    def elapsed_ms(self) -> float:
        """Return elapsed time in milliseconds."""
        elapsed_ns = time.perf_counter_ns() - self.start_time_ns
        return elapsed_ns / 1_000_000


def read_message() -> Optional[dict[str, Any]]:
    """
    Read a JSON-RPC message from stdin using Content-Length framing.

    Returns:
        Parsed message dict or None if EOF/error

    Protocol:
        Content-Length: <bytes>\r\n
        \r\n
        <json body>
    """
    try:
        # Read Content-Length header line from binary stream
        header_bytes = b""
        while True:
            byte = sys.stdin.buffer.read(1)
            if not byte:
                return None  # EOF
            header_bytes += byte
            if header_bytes.endswith(b"\r\n"):
                break

        if not header_bytes.startswith(b"Content-Length:"):
            # Protocol error - skip to next line and try again
            return read_message()

        try:
            length = int(header_bytes.split(b":", 1)[1].strip())
        except ValueError, IndexError:
            log_error(
                f"Invalid Content-Length header: {header_bytes.decode('utf-8', errors='replace')}"
            )
            return None

        # Read empty separator line (\r\n)
        sep = sys.stdin.buffer.read(2)
        if sep != b"\r\n":
            # Malformed message, but try to continue
            pass

        # Read the JSON body (exact number of bytes)
        body_bytes = sys.stdin.buffer.read(length)
        if len(body_bytes) < length:
            log_error(f"Incomplete read: expected {length}, got {len(body_bytes)}")
            return None

        # Parse JSON
        try:
            body = body_bytes.decode("utf-8")
            return json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            log_error(f"JSON decode error: {e}")
            return None

    except Exception as e:
        log_error(f"Error reading message: {e}")
        return None


def write_message(msg: dict[str, Any]) -> None:
    """
    Write a JSON-RPC message to stdout with Content-Length framing.

    Args:
        msg: The message dict to send

    Format:
        Content-Length: <bytes>\r\n\r\n<json body>
    """
    body = json.dumps(msg, separators=(",", ":"), ensure_ascii=False)
    body_bytes = body.encode("utf-8")
    framed = f"Content-Length: {len(body_bytes)}\r\n\r\n".encode("utf-8") + body_bytes

    sys.stdout.buffer.write(framed)
    sys.stdout.buffer.flush()


def send_response(result: Any, msg_id: Any) -> None:
    """Send a JSON-RPC success response."""
    response = {"jsonrpc": "2.0", "id": msg_id, "result": result}
    write_message(response)


def send_error(code: int, message: str, msg_id: Any, data: Any = None) -> None:
    """Send a JSON-RPC error response."""
    error = {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": code, "message": message},
    }
    if data is not None:
        error["error"]["data"] = data
    write_message(error)


def send_notification(method: str, params: dict[str, Any]) -> None:
    """Send a JSON-RPC notification (no response expected)."""
    notification = {"jsonrpc": "2.0", "method": method, "params": params}
    write_message(notification)


def log_info(msg: str) -> None:
    """Log info message to stderr."""
    print(f"[INFO] {msg}", file=sys.stderr, flush=True)


def log_error(msg: str) -> None:
    """Log error message to stderr."""
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)


# ============================================================================
# Method Handlers
# ============================================================================


def handle_initialize(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """
    Handle initialize request.

    Returns worker capabilities and signals ready state.
    """
    result = {
        "status": "ready",
        "pid": os.getpid(),
        "timestamp_ns": time.perf_counter_ns(),
        "capabilities": {
            "methods": ["initialize", "echo", "sleep", "crash", "shutdown", "stats"],
            "protocol_version": "2.0",
        },
    }
    send_response(result, msg_id)
    return True


def handle_echo(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """
    Handle echo request.

    Echoes back the params with additional timing info.
    """
    result = {
        "echo": params,
        "received_ns": time.perf_counter_ns(),
        "requests_served": stats.requests_handled,
    }
    send_response(result, msg_id)
    return True


def handle_sleep(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """
    Handle sleep request.

    Params:
        duration: float - seconds to sleep (default: 0.1)
    """
    duration = params.get("duration", 0.1)

    # Use the most precise sleep available
    start = time.perf_counter()
    time.sleep(duration)
    actual_duration = time.perf_counter() - start

    result = {
        "requested_duration": duration,
        "actual_duration": actual_duration,
        "timestamp_ns": time.perf_counter_ns(),
    }
    send_response(result, msg_id)
    return True


def handle_crash(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """
    Handle crash request.

    Intentionally crashes the worker for fault recovery testing.
    Sends response before crashing if 'graceful' param is true.
    """
    graceful = params.get("graceful", False)
    exit_code = params.get("exit_code", ExitCode.INTENTIONAL_CRASH)
    delay = params.get("delay", 0.0)

    if graceful:
        result = {"crashing": True, "exit_code": exit_code, "pid": os.getpid()}
        send_response(result, msg_id)
        time.sleep(delay)

    # Crash the process
    log_info(f"Intentional crash requested (exit_code={exit_code})")
    sys.exit(exit_code)


def handle_stats(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """Handle stats request - return worker statistics."""
    result = {
        "requests_handled": stats.requests_handled,
        "elapsed_ms": stats.elapsed_ms,
        "pid": os.getpid(),
    }
    send_response(result, msg_id)
    return True


def handle_shutdown(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """
    Handle shutdown request.

    Gracefully shuts down the worker.
    Returns False to signal exit.
    """
    result = {
        "status": "shutting_down",
        "requests_handled": stats.requests_handled,
        "elapsed_ms": stats.elapsed_ms,
        "pid": os.getpid(),
    }
    send_response(result, msg_id)
    return False


def handle_ping(params: dict[str, Any], msg_id: Any, stats: WorkerStats) -> bool:
    """Handle ping request for health checks."""
    result = {"status": "ok", "timestamp_ns": time.perf_counter_ns()}
    send_response(result, msg_id)
    return True


# ============================================================================
# Dispatcher
# ============================================================================

HANDLERS: dict[str, callable] = {
    "initialize": handle_initialize,
    "echo": handle_echo,
    "sleep": handle_sleep,
    "crash": handle_crash,
    "stats": handle_stats,
    "shutdown": handle_shutdown,
    "ping": handle_ping,
}


def dispatch(msg: dict[str, Any], stats: WorkerStats) -> bool:
    """
    Dispatch a JSON-RPC message to the appropriate handler.

    Args:
        msg: The parsed JSON-RPC message
        stats: Worker statistics tracker

    Returns:
        True to continue, False to exit
    """
    method = msg.get("method", "")
    params = msg.get("params", {})
    msg_id = msg.get("id")  # May be None for notifications

    handler = HANDLERS.get(method)

    if handler:
        try:
            return handler(params, msg_id, stats)
        except Exception as e:
            log_error(f"Handler error for {method}: {e}")
            if msg_id is not None:
                send_error(-32603, f"Internal error: {e}", msg_id)
            return True
    elif msg_id is not None:
        # Unknown method - return error for requests
        send_error(-32601, f"Method not found: {method}", msg_id)
    # Unknown notification - just log
    log_info(f"Unknown notification: {method}")
    return True


def setup_signal_handlers() -> None:
    """Setup signal handlers for graceful shutdown."""

    def handle_sigterm(signum, frame):
        log_info("Received SIGTERM, exiting")
        sys.exit(0)

    def handle_sigint(signum, frame):
        log_info("Received SIGINT, exiting")
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigint)


def main() -> int:
    """
    Main entry point for the benchmark worker.

    Returns:
        Exit code (0 for success)
    """
    setup_signal_handlers()

    stats = WorkerStats()
    log_info(f"Worker started (PID: {os.getpid()})")

    # Send initial ready notification
    send_notification(
        "system.ready",
        {"status": "ready", "pid": os.getpid(), "timestamp_ns": time.perf_counter_ns()},
    )

    running = True
    while running:
        msg = read_message()
        if msg is None:
            log_info("EOF received, exiting normally")
            break

        stats.requests_handled += 1
        running = dispatch(msg, stats)

    log_info(f"Worker exiting (handled {stats.requests_handled} requests)")
    return ExitCode.NORMAL


if __name__ == "__main__":
    try:
        exit_code = main()
    except Exception as e:
        log_error(f"Fatal error: {e}")
        import traceback

        traceback.print_exc()
        exit_code = ExitCode.ERROR

    sys.exit(exit_code)
