"""Process Runner Protocol - Abstract interface for process execution.

This module defines the protocol/abstract interface that can be implemented by:
- Current Python subprocess (default)
- Elixir Port runner for native process management
- Any other process execution backend

Design Goals:
- Async-first API for non-blocking I/O
- Streaming support for real-time output
- Process lifecycle management (spawn, kill, query)
- Clean separation of concerns for Elixir migration

Usage:
    # Current Python implementation
    from code_puppy.tools.process_runner_impl import SubprocessRunner

    runner: ProcessRunner = SubprocessRunner()

    async for chunk in runner.spawn("ls", ["-la"], cwd="/tmp"):
        print(chunk.decode())

Future Elixir integration:
    # Via JSON-RPC over stdio to Elixir Port
    from code_puppy.plugins.elixir_bridge.runner import ElixirPortRunner

    runner: ProcessRunner = ElixirPortRunner()
    # Same API, different backend

See: docs/architecture/python-singleton-audit.md for migration context.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, AsyncIterator, Protocol, runtime_checkable

# =============================================================================
# Enums and Types
# =============================================================================


class ProcessStatus(str, Enum):
    """Lifecycle states for a managed process."""

    PENDING = "pending"  # Spawn requested but not yet started
    RUNNING = "running"  # Process is actively executing
    COMPLETED = "completed"  # Process finished successfully (exit_code=0)
    FAILED = "failed"  # Process finished with non-zero exit
    TIMEOUT = "timeout"  # Process killed due to timeout
    KILLED = "killed"  # Process killed by user/request
    ERROR = "error"  # Spawn failed (couldn't start)


class StreamType(str, Enum):
    """Output stream types."""

    STDOUT = "stdout"
    STDERR = "stderr"


# =============================================================================
# Data Classes
# =============================================================================


@dataclass(frozen=True)
class ProcessResult:
    """Final result of a process execution.

    This captures the complete outcome after process termination.
    For streaming output, use spawn() which yields chunks.
    """

    exit_code: int
    stdout: str
    stderr: str
    execution_time_seconds: float
    killed_by_user: bool = False
    timeout_triggered: bool = False


@dataclass(frozen=True)
class ProcessInfo:
    """Runtime information about a managed process.

    Used for status queries and process management.
    """

    process_id: str
    pid: int | None  # OS process ID (if available)
    status: ProcessStatus
    command: str
    args: list[str]
    cwd: str | None
    start_time: float  # Unix timestamp
    exit_code: int | None = None
    error_message: str | None = None


@dataclass(frozen=True)
class ProcessChunk:
    """A chunk of output from a running process.

    Yields from spawn() async iterator for streaming output.
    """

    data: bytes
    stream: StreamType
    timestamp: float  # Unix timestamp


@dataclass(frozen=True)
class SpawnOptions:
    """Options for process spawning.

    Encapsulates all optional parameters to avoid long parameter lists.
    """

    cwd: str | None = None
    env: dict[str, str] | None = None
    timeout_seconds: float | None = None
    use_shell: bool = False  # If True, command is interpreted by shell
    background: bool = False  # If True, don't wait for completion
    max_line_length: int | None = None  # For output truncation
    log_file: str | None = None  # For background process output capture


# =============================================================================
# Protocol Definition
# =============================================================================


@runtime_checkable
class ProcessRunner(Protocol):
    """Protocol for process execution backends.

    Implementations:
        - SubprocessRunner: Python subprocess.Popen backend (current)
        - ElixirPortRunner: Native runner via Elixir Port

    All methods are async to support both sync and async backends uniformly.

    Example:
        async def run_ls(runner: ProcessRunner) -> None:
            chunks: list[bytes] = []
            async for chunk in runner.spawn("ls", ["-la"], "/tmp"):
                chunks.append(chunk.data)

            # Or get final result
            result = await runner.run_to_completion("ls", ["-la"])
            print(result.stdout)
    """

    async def spawn(
        self,
        command: str,
        args: list[str],
        options: SpawnOptions | None = None,
    ) -> AsyncIterator[ProcessChunk]:
        """Spawn a process and stream its output.

        This is the primary interface for real-time process execution.
        The async iterator yields output chunks as they become available.

        Args:
            command: The command/program to execute
            args: Arguments to pass to the command
            options: Spawn options (cwd, env, timeout, etc.)

        Yields:
            ProcessChunk: Output chunks with stream type (stdout/stderr)

        Raises:
            ProcessSpawnError: If the process fails to start
            ProcessTimeoutError: If timeout is exceeded

        Example:
            async for chunk in runner.spawn("python", ["script.py"], options):
                if chunk.stream == StreamType.STDOUT:
                    print(chunk.data.decode())
        """
        ...

    async def run_to_completion(
        self,
        command: str,
        args: list[str],
        options: SpawnOptions | None = None,
    ) -> ProcessResult:
        """Run a process to completion and return the full result.

        Convenience method for non-streaming use cases. Collects all
        output and waits for process termination.

        Args:
            command: The command/program to execute
            args: Arguments to pass to the command
            options: Spawn options (cwd, env, timeout, etc.)

        Returns:
            ProcessResult: Complete execution result

        Raises:
            ProcessSpawnError: If the process fails to start
            ProcessTimeoutError: If timeout is exceeded
        """
        ...

    async def kill(self, process_id: str, force: bool = False) -> bool:
        """Kill a running process.

        Args:
            process_id: The process ID returned by spawn/query
            force: If True, use SIGKILL/force kill (otherwise SIGTERM)

        Returns:
            True if process was killed, False if not found or already dead

        Raises:
            ProcessNotFoundError: If process_id doesn't exist
        """
        ...

    async def get_info(self, process_id: str) -> ProcessInfo | None:
        """Get current information about a process.

        Args:
            process_id: The process ID to query

        Returns:
            ProcessInfo if process exists, None otherwise
        """
        ...

    async def list_running(self) -> list[ProcessInfo]:
        """List all currently running processes managed by this runner.

        Returns:
            List of ProcessInfo for active processes
        """
        ...

    async def kill_all(self, force: bool = False) -> int:
        """Kill all running processes.

        Useful for shutdown/cleanup scenarios.

        Args:
            force: If True, use force kill on all processes

        Returns:
            Number of processes killed
        """
        ...


# =============================================================================
# Exceptions
# =============================================================================


class ProcessRunnerError(Exception):
    """Base exception for process runner errors."""

    pass


class ProcessSpawnError(ProcessRunnerError):
    """Raised when a process fails to start."""

    def __init__(self, command: str, reason: str):
        self.command = command
        self.reason = reason
        super().__init__(f"Failed to spawn '{command}': {reason}")


class ProcessTimeoutError(ProcessRunnerError):
    """Raised when a process exceeds its timeout."""

    def __init__(
        self, process_id: str, timeout: float, partial_output: bytes | None = None
    ):
        self.process_id = process_id
        self.timeout = timeout
        self.partial_output = partial_output
        super().__init__(f"Process {process_id} exceeded timeout of {timeout}s")


class ProcessNotFoundError(ProcessRunnerError):
    """Raised when a process is not found."""

    def __init__(self, process_id: str):
        self.process_id = process_id
        super().__init__(f"Process '{process_id}' not found")


class ProcessKillError(ProcessRunnerError):
    """Raised when killing a process fails."""

    def __init__(self, process_id: str, reason: str):
        self.process_id = process_id
        self.reason = reason
        super().__init__(f"Failed to kill process '{process_id}': {reason}")


# =============================================================================
# Validation Helpers
# =============================================================================


def validate_process_runner(impl: Any) -> None:
    """Validate that an object implements the ProcessRunner protocol.

    Args:
        impl: Object to validate

    Raises:
        TypeError: If the object doesn't implement ProcessRunner

    Example:
        runner = SubprocessRunner()
        validate_process_runner(runner)  # Passes if correctly implemented
    """
    required_methods = [
        "spawn",
        "run_to_completion",
        "kill",
        "get_info",
        "list_running",
        "kill_all",
    ]

    for method in required_methods:
        if not hasattr(impl, method):
            raise TypeError(
                f"ProcessRunner implementation missing required method: {method}"
            )
        if not callable(getattr(impl, method)):
            raise TypeError(f"ProcessRunner.{method} must be callable")


# =============================================================================
# Type Aliases for Elixir Bridge
# =============================================================================

# JSON-RPC message types for Elixir Port communication
JSONRPCRequest = dict[
    str, Any
]  # {"jsonrpc": "2.0", "id": str, "method": str, "params": dict}
JSONRPCResponse = dict[
    str, Any
]  # {"jsonrpc": "2.0", "id": str, "result": Any} or with "error"
JSONRPCNotification = dict[
    str, Any
]  # {"jsonrpc": "2.0", "method": str, "params": dict}


# =============================================================================
# Export all public symbols
# =============================================================================

__all__ = [
    # Enums
    "ProcessStatus",
    "StreamType",
    # Data classes
    "ProcessResult",
    "ProcessInfo",
    "ProcessChunk",
    "SpawnOptions",
    # Protocol
    "ProcessRunner",
    # Exceptions
    "ProcessRunnerError",
    "ProcessSpawnError",
    "ProcessTimeoutError",
    "ProcessNotFoundError",
    "ProcessKillError",
    # Validation
    "validate_process_runner",
    # Type aliases
    "JSONRPCRequest",
    "JSONRPCResponse",
    "JSONRPCNotification",
]
