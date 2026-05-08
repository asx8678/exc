"""
Standalone Elixir transport client for file operations.

This module provides a Python client adapter that communicates with the
Elixir stdio service via JSON-RPC. Provides FileOps API
for drop-in replacement.

## Usage

```python
from code_puppy.elixir_transport import ElixirTransport

# Start the transport (spawns Elixir process)
transport = ElixirTransport()
transport.start()

# List files
files = transport.list_files(".", recursive=True)

# Read a file
result = transport.read_file("path/to/file.py")
print(result["content"])

# Search in files
matches = transport.grep("def ", ".", case_sensitive=True)

# Shutdown
transport.stop()
```

## When to Use

**Use elixir_transport when:**
- You need the Elixir FileOps implementation standalone
- You're building scripts that work with the Elixir control plane
- You want simple subprocess communication without Rust dependencies

**Use bridge mode (PythonWorker.Port) when:**
- Running within the full CodePuppy application
- You need PubSub event distribution
- You want full OTP supervision

## Environment Variables

- `PUP_ELIXIR_PATH` - Path to elixir/mix executable directory (default: auto-detect)
- `PUP_ELIXIR_SERVICE_CMD` - Override the command to start the service
- `PUP_LOG_LEVEL` - Set Elixir service log level (debug, info, warn, error)

TODO(python-bridge-transport-pooling): Add connection pooling for multiple concurrent transports
TODO(python-bridge-unix-socket): Add Unix socket transport option for better performance
"""

import json
import logging
import os
import select
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


class ElixirTransportError(Exception):
    """Raised when the Elixir transport encounters an error."""

    pass


class ElixirTransport:
    """
    Client adapter for the Elixir stdio JSON-RPC service.

    This class manages a subprocess running the Elixir stdio service
    and provides a Pythonic API for file operations.
    """

    def __init__(
        self,
        elixir_path: str | None = None,
        project_path: str | None = None,
        timeout: float = 30.0,
    ):
        """
        Initialize the transport.

        Args:
            elixir_path: Path to elixir/mix executables. Auto-detected if None.
            project_path: Path to the code_puppy_control Elixir project.
                          Auto-detected relative to this file if None.
            timeout: Default timeout for operations in seconds.
        """
        self.elixir_path = elixir_path or self._detect_elixir_path()
        self.project_path = project_path or self._detect_project_path()
        self.timeout = timeout

        self._process: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._request_id = 0
        self._closed = False

    def _detect_elixir_path(self) -> str:
        """Auto-detect the path to elixir/mix."""
        elixir_exe = shutil.which("elixir")
        if elixir_exe:
            return os.path.dirname(elixir_exe)

        # Check common locations
        common_paths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",  # macOS Homebrew on Apple Silicon
            "/usr/bin",
            os.path.expanduser("~/.mix/escripts"),
        ]

        for path in common_paths:
            if os.path.exists(os.path.join(path, "elixir")):
                return path

        raise ElixirTransportError(
            "Could not find elixir executable. "
            "Please install Elixir or set PUP_ELIXIR_PATH."
        )

    def _detect_project_path(self) -> str:
        """Auto-detect the path to the Elixir project."""
        # Look for the elixir directory relative to this file
        # code_puppy/elixir_transport.py -> elixir/code_puppy_control
        current_file = Path(__file__).resolve()
        project_root = current_file.parent.parent

        # Try several possible locations
        possible_paths = [
            project_root / "elixir" / "code_puppy_control",
            project_root / ".." / "elixir" / "code_puppy_control",
            project_root / ".." / ".." / "elixir" / "code_puppy_control",
        ]

        for path in possible_paths:
            if (path / "mix.exs").exists():
                return str(path.resolve())

        raise ElixirTransportError(
            f"Could not find code_puppy_control Elixir project. "
            f"Searched: {[str(p) for p in possible_paths]}"
        )

    def start(self) -> "ElixirTransport":
        """
        Start the Elixir stdio service subprocess.

        Returns:
            self for method chaining

        Raises:
            ElixirTransportError: If the service fails to start
        """
        if self._process is not None:
            raise ElixirTransportError("Transport already started")

        # Determine the command to run
        cmd = self._get_service_command()

        logger.debug(f"Starting Elixir stdio service: {' '.join(cmd)}")
        logger.debug(f"Working directory: {self.project_path}")

        try:
            # Disable Erlang BREAK handler and isolate from terminal signals
            # so Ctrl+C in the Python terminal doesn't corrupt the JSON-RPC stream
            env = os.environ.copy()
            env["ERL_AFLAGS"] = "+B"  # Disable interactive BREAK handler
            self._process = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,  # Line buffered
                cwd=self.project_path,
                start_new_session=True,  # Isolate from terminal SIGINT
                env=env,
            )
        except OSError as e:
            raise ElixirTransportError(f"Failed to start Elixir service: {e}")

        # Wait for service to be ready
        self._wait_for_ready()

        logger.info("Elixir stdio service started")
        return self

    def _get_service_command(self) -> list[str]:
        """Get the command to start the stdio service."""
        # Check for override
        override = os.environ.get("PUP_ELIXIR_SERVICE_CMD")
        if override:
            return override.split()

        # Use mix task
        mix_exe = os.path.join(self.elixir_path, "mix")
        if not os.path.exists(mix_exe):
            mix_exe = "mix"  # Assume it's in PATH

        return [mix_exe, "code_puppy.stdio_service"]

    def _wait_for_ready(self, timeout_sec: float = 10.0) -> None:
        """Wait for the service to be ready by sending a ping."""
        if self._process is None or self._process.poll() is not None:
            raise ElixirTransportError("Service process not running")

        # Give the service time to fully start
        time.sleep(0.5)

        start_time = time.time()
        ping_id = 1

        while time.time() - start_time < timeout_sec:
            # Check if process died
            if self._process.poll() is not None:
                stderr = ""
                if self._process.stderr:
                    stderr = self._process.stderr.read()
                raise ElixirTransportError(
                    f"Service process exited with code {self._process.returncode}. "
                    f"Stderr: {stderr[:500]}"
                )

            try:
                # Send ping (same id until we get a matching pong)
                request = {
                    "jsonrpc": "2.0",
                    "id": ping_id,
                    "method": "ping",
                    "params": {},
                }
                req_line = json.dumps(request) + "\n"
                self._process.stdin.write(req_line)
                self._process.stdin.flush()

                # Read ALL available lines to find our pong
                # (drains _ready handshake, stale output, etc.)
                wait_start = time.time()
                while time.time() - wait_start < 2.0:
                    ready, _, _ = select.select([self._process.stdout], [], [], 0.1)
                    if ready:
                        line = self._process.stdout.readline()
                        if line:
                            stripped = line.strip()
                            if not stripped:
                                continue
                            try:
                                response = json.loads(stripped)
                                if response.get("id") == ping_id and response.get(
                                    "result", {}
                                ).get("pong"):
                                    # Success! Drain any remaining startup noise
                                    drained_count = self._drain_startup_stdout(
                                        timeout_sec=0.5
                                    )
                                    if drained_count > 0:
                                        logger.warning(
                                            f"Drained {drained_count} stale bytes from stdout during startup"
                                        )
                                    with self._lock:
                                        self._request_id = ping_id
                                    return
                                else:
                                    logger.debug(
                                        f"Discarding non-matching response during startup: {stripped[:100]}"
                                    )
                            except json.JSONDecodeError:
                                logger.debug(
                                    f"Discarding non-JSON line during startup: {stripped[:100]}"
                                )
                    else:
                        # No data available, retry ping
                        break

            except Exception as e:
                logger.debug(f"Wait for ready attempt failed: {e}")

            time.sleep(0.3)

        raise ElixirTransportError("Timeout waiting for service to be ready")

    def _drain_startup_stdout(self, timeout_sec: float = 0.5) -> int:
        """
        Drain any pending bytes from stdout during startup.

        This is used to clear out stale pongs, late log lines, or other
        buffered output that arrived before we were ready to read.

        Args:
            timeout_sec: Maximum time to spend draining

        Returns:
            Number of bytes/chars drained
        """
        if self._process is None or self._process.poll() is not None:
            return 0

        drained_total = 0
        start_time = time.time()

        while time.time() - start_time < timeout_sec:
            # Check if data is available (non-blocking with short timeout)
            ready, _, _ = select.select([self._process.stdout], [], [], 0.05)
            if not ready:
                # No more data available, we're done
                break

            # Read available data
            try:
                line = self._process.stdout.readline()
                if line:
                    stripped = line.strip()
                    drained_total += len(line)
                    if stripped:
                        logger.debug(
                            f"Drained from stdout during startup: {stripped[:200]}"
                        )
                else:
                    # EOF reached
                    break
            except Exception as e:
                logger.debug(f"Error draining stdout: {e}")
                break

        return drained_total

    def stop(self) -> None:
        """Stop the Elixir stdio service."""
        if self._process is None:
            return

        with self._lock:
            if self._closed:
                return

            self._closed = True

            # Send shutdown signal (EOF)
            if self._process.stdin:
                self._process.stdin.close()

            # Wait for graceful shutdown
            try:
                self._process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                logger.warning("Service did not stop gracefully, terminating")
                self._process.terminate()
                try:
                    self._process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait()

            logger.info("Elixir stdio service stopped")
            self._process = None

    def is_alive(self) -> bool:
        """Check whether the Elixir subprocess is still running."""
        return self._process is not None and self._process.poll() is None

    def _send_request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """
        Send a JSON-RPC request and wait for response.

        Args:
            method: The JSON-RPC method name
            params: The method parameters

        Returns:
            The response result

        Raises:
            ElixirTransportError: If the request fails
        """
        if self._process is None:
            raise ElixirTransportError(
                "Transport was never started. Call start() before sending requests."
            )
        if self._process.poll() is not None:
            # auto-restart with backoff on subprocess death
            exit_code = self._process.returncode
            logger.warning(
                "Elixir process died (exit code %s). "
                "Attempting auto-restart with backoff...",
                exit_code,
            )
            # Reset state so start() will accept a new process
            self._process = None
            self._closed = False
            # Backoff before restarting to let things settle
            time.sleep(0.5)
            try:
                self.start()
            except ElixirTransportError:
                logger.error("Auto-restart failed")
                raise
            # Double-check the restarted process is alive
            if self._process is None or self._process.poll() is not None:
                code = self._process.returncode if self._process else "N/A"
                raise ElixirTransportError(
                    f"Auto-restart failed: process died again (exit code {code})."
                )
            logger.info("Auto-restart succeeded, resuming request")

        # Lock protects the entire send+receive cycle to ensure request/response
        # matching and prevent interleaving of concurrent requests
        with self._lock:
            self._request_id += 1
            request_id = self._request_id

            request = {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            }

            request_line = json.dumps(request) + "\n"
            logger.debug(f"Sending request: {request_line.strip()}")

            try:
                self._process.stdin.write(request_line)
                self._process.stdin.flush()
            except (BrokenPipeError, OSError) as e:
                raise ElixirTransportError(f"Failed to send request: {e}")

            # Read response (skip non-JSON lines that may be warnings/startup messages)
            max_non_json_reads: int = 50
            max_wait_seconds: float = 5.0
            start_time = time.time()
            response_line: str = ""
            response: dict[str, Any] | None = None

            for _ in range(max_non_json_reads):
                # Time budget check before blocking readline()
                if time.time() - start_time > max_wait_seconds:
                    raise ElixirTransportError(
                        f"Timed out after {max_wait_seconds}s waiting for valid JSON response with id={request_id}"
                    )
                line = self._process.stdout.readline()
                if not line:
                    raise ElixirTransportError(
                        "Empty response from service (process died?)"
                    )
                line = line.strip()
                if not line:
                    continue  # Skip empty lines

                try:
                    response = json.loads(line)
                    # Validate the response has the expected request id
                    if response.get("id") == request_id:
                        response_line = line
                        break
                    else:
                        # Valid JSON but wrong id - could be a stray response
                        logger.warning(
                            f"Discarding response with mismatched id: {line[:100]}"
                        )
                        response = None
                except json.JSONDecodeError:
                    # Not valid JSON - log and continue searching
                    logger.warning(f"Discarding non-JSON line: {line[:100]}")
                    continue

            if response is None:
                raise ElixirTransportError(
                    f"No valid JSON response with id={request_id} after "
                    f"{max_non_json_reads} attempts"
                )

            logger.debug(f"Received response: {response_line.strip()}")

            # Handle error responses
            if "error" in response:
                error = response["error"]
                raise ElixirTransportError(
                    f"Request failed: {error.get('message', 'Unknown error')} "
                    f"(code: {error.get('code', 'N/A')})"
                )

        return response.get("result", {})

    # ============================================================================
    # Public API
    # ============================================================================

    def ping(self) -> dict[str, Any]:
        """
        Send a ping to check if the service is responsive.

        Returns:
            Dict with "pong" and "timestamp" fields
        """
        return self._send_request("ping", {})

    def health_check(self) -> dict[str, Any]:
        """
        Get detailed health status from the service.

        Returns:
            Dict with status, version, elixir_version, otp_version, timestamp
        """
        return self._send_request("health_check", {})

    def list_files(
        self,
        directory: str = ".",
        recursive: bool = True,
        include_hidden: bool = False,
        ignore_patterns: list[str] | None = None,
        max_files: int = 10_000,
    ) -> list[dict[str, Any]]:
        """
        List files in a directory.

        Args:
            directory: Path to list
            recursive: Whether to recurse into subdirectories
            include_hidden: Whether to include hidden files
            ignore_patterns: List of glob patterns to ignore
            max_files: Maximum number of files to return

        Returns:
            List of file info dicts with path, type, size, modified fields

        Raises:
            ElixirTransportError: If the directory cannot be listed
        """
        params: dict[str, Any] = {
            "directory": directory,
            "recursive": recursive,
            "include_hidden": include_hidden,
            "max_files": max_files,
        }
        if ignore_patterns:
            params["ignore_patterns"] = ignore_patterns

        result = self._send_request("file_list", params)
        return result.get("files", [])

    def read_file(
        self,
        path: str,
        start_line: int | None = None,
        num_lines: int | None = None,
    ) -> dict[str, Any]:
        """
        Read a single file's contents.

        Args:
            path: Path to the file
            start_line: 1-based starting line number (optional)
            num_lines: Maximum number of lines to read (optional)

        Returns:
            Dict with path, content, num_lines, size, truncated, error fields

        Raises:
            ElixirTransportError: If the file cannot be read
        """
        params: dict[str, Any] = {"path": path}
        if start_line is not None:
            params["start_line"] = start_line
        if num_lines is not None:
            params["num_lines"] = num_lines

        return self._send_request("file_read", params)

    def read_files(
        self,
        paths: list[str],
        start_line: int | None = None,
        num_lines: int | None = None,
    ) -> list[dict[str, Any]]:
        """
        Read multiple files concurrently.

        Args:
            paths: List of file paths
            start_line: 1-based starting line number (optional)
            num_lines: Maximum number of lines to read (optional)

        Returns:
            List of file result dicts

        Raises:
            ElixirTransportError: If the batch request fails
        """
        params: dict[str, Any] = {"paths": paths}
        if start_line is not None:
            params["start_line"] = start_line
        if num_lines is not None:
            params["num_lines"] = num_lines

        result = self._send_request("file_read_batch", params)
        return result.get("files", [])

    def grep(
        self,
        pattern: str,
        directory: str = ".",
        case_sensitive: bool = True,
        max_matches: int = 1_000,
        file_pattern: str = "*",
        context_lines: int = 0,
    ) -> list[dict[str, Any]]:
        """
        Search for a pattern in files.

        Args:
            pattern: Regex pattern to search for
            directory: Directory to search in
            case_sensitive: Whether the search is case-sensitive
            max_matches: Maximum number of matches to return
            file_pattern: Glob pattern to filter files
            context_lines: Number of context lines around matches (not yet implemented)

        Returns:
            List of match dicts with file, line_number, line_content, match_start, match_end

        Raises:
            ElixirTransportError: If the search fails or pattern is invalid
        """
        params: dict[str, Any] = {
            "pattern": pattern,
            "directory": directory,
            "case_sensitive": case_sensitive,
            "max_matches": max_matches,
            "file_pattern": file_pattern,
            "context_lines": context_lines,
        }

        result = self._send_request("grep_search", params)
        return result.get("matches", [])

    # ============================================================================
    # Session Storage API (Ecto/SQLite backed)
    # ============================================================================

    def session_save(
        self,
        name: str,
        history: list[dict[str, Any]],
        compacted_hashes: list[str] | None = None,
        total_tokens: int = 0,
        auto_saved: bool = False,
        timestamp: str | None = None,
        has_terminal: bool = False,
        terminal_meta: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """
        Save a chat session to the database.

        Args:
            name: Session identifier
            history: List of message dicts
            compacted_hashes: List of hash strings for compacted messages
            total_tokens: Total token count
            auto_saved: Whether this was auto-saved
            timestamp: ISO8601 timestamp (defaults to now)
            has_terminal: Whether session has an active terminal (code_puppy-ctj.1)
            terminal_meta: Terminal metadata for crash recovery (code_puppy-ctj.1)

        Returns:
            Dict with success, name, message_count, total_tokens fields

        Raises:
            ElixirTransportError: If the save fails
        """
        params: dict[str, Any] = {
            "name": name,
            "history": history,
            "compacted_hashes": compacted_hashes or [],
            "total_tokens": total_tokens,
            "auto_saved": auto_saved,
            "has_terminal": has_terminal,
        }
        if timestamp:
            params["timestamp"] = timestamp
        if terminal_meta:
            params["terminal_meta"] = terminal_meta

        return self._send_request("session_save", params)

    def session_load(self, name: str) -> dict[str, Any]:
        """
        Load a session by name.

        Args:
            name: Session identifier

        Returns:
            Dict with history and compacted_hashes fields

        Raises:
            ElixirTransportError: If the session doesn't exist or load fails
        """
        return self._send_request("session_load", {"name": name})

    def session_load_full(self, name: str) -> dict[str, Any]:
        """
        Load a session with full metadata.

        Args:
            name: Session identifier

        Returns:
            Dict with full session details including name, history,
            compacted_hashes, message_count, total_tokens,
            auto_saved, timestamp, created_at, updated_at

        Raises:
            ElixirTransportError: If the session doesn't exist or load fails
        """
        return self._send_request("session_load_full", {"name": name})

    def session_list(self) -> list[str]:
        """
        List all session names.

        Returns:
            Sorted list of session names
        """
        result = self._send_request("session_list", {})
        return result.get("sessions", [])

    def session_list_with_metadata(self) -> list[dict[str, Any]]:
        """
        List all sessions with metadata.

        Returns:
            List of session dicts sorted by timestamp (newest first)
        """
        result = self._send_request("session_list_with_metadata", {})
        return result.get("sessions", [])

    def session_delete(self, name: str) -> bool:
        """
        Delete a session by name.

        Args:
            name: Session identifier

        Returns:
            True if deleted (or didn't exist)

        Raises:
            ElixirTransportError: If deletion fails
        """
        result = self._send_request("session_delete", {"name": name})
        return result.get("deleted", False)

    def session_cleanup(self, max_sessions: int = 10) -> list[str]:
        """
        Clean up old sessions, keeping only the most recent N.

        Args:
            max_sessions: Maximum number of sessions to keep

        Returns:
            List of deleted session names
        """
        result = self._send_request("session_cleanup", {"max_sessions": max_sessions})
        return result.get("deleted", [])

    def session_exists(self, name: str) -> bool:
        """
        Check if a session exists.

        Args:
            name: Session identifier

        Returns:
            True if the session exists
        """
        result = self._send_request("session_exists", {"name": name})
        return result.get("exists", False)

    def session_count(self) -> int:
        """
        Get the total count of sessions.

        Returns:
            Total number of sessions
        """
        result = self._send_request("session_count", {})
        return result.get("count", 0)

    # ============================================================================
    # Terminal Session Tracking (code_puppy-ctj.1)
    # ============================================================================

    def session_register_terminal(
        self,
        name: str,
        session_id: str | None = None,
        cols: int = 80,
        rows: int = 24,
        shell: str | None = None,
    ) -> dict[str, Any]:
        """Register a terminal session for crash recovery tracking."""
        params: dict[str, Any] = {
            "name": name,
            "session_id": session_id or name,
            "cols": cols,
            "rows": rows,
        }
        if shell:
            params["shell"] = shell
        return self._send_request("session_register_terminal", params)

    def session_unregister_terminal(self, name: str) -> dict[str, Any]:
        """Unregister a terminal session from crash recovery tracking."""
        return self._send_request("session_unregister_terminal", {"name": name})

    def session_list_terminals(self) -> list[dict[str, Any]]:
        """List all tracked terminal sessions."""
        result = self._send_request("session_list_terminals", {})
        return result.get("terminals", [])

    # ============================================================================
    # Context Manager Support
    # ============================================================================

    def __enter__(self) -> "ElixirTransport":
        """Context manager entry."""
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Context manager exit."""
        self.stop()

    def __del__(self):
        """Cleanup on garbage collection."""
        if self._process is not None and not self._closed:
            try:
                self.stop()
            except Exception:
                pass


# =============================================================================
# Deprecated: Module-level convenience functions have moved
# =============================================================================
#
# For simple use cases, import from elixir_transport_helpers instead:
# from code_puppy import elixir_transport_helpers as elixir
# files = elixir.list_files(".")
#
# For explicit control, use the ElixirTransport class directly.
# =============================================================================
