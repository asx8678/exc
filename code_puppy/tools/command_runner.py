"""Shell command execution for agent tool calls.

SECURITY NOTE: shell=True is intentionally used for all subprocess.Popen calls.
Commands arrive as complete strings from the LLM (e.g. "cd /foo && make test"
or "cat file | grep pattern") and REQUIRE shell interpretation for pipes,
redirects, chains, and variable expansion. Removing shell=True would break
all non-trivial commands.

Security is enforced UPSTREAM by the shell_safety plugin, which classifies
commands before execution and can block dangerous operations. The PolicyEngine
provides additional rule-based command filtering.
"""

import asyncio
import ctypes
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import sys as _sys  # For version check in _run_command_sync
import tempfile
import threading
import time
import traceback
from collections import deque
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from functools import partial
from typing import Literal

from pydantic import BaseModel
from pydantic_ai import RunContext
from rich.text import Text

from code_puppy.concurrency_limits import ToolCallsLimiter
from code_puppy.config import get_puppy_name, get_yolo_mode
from code_puppy.messaging import (  # Structured messaging types
    AgentReasoningMessage,
    ShellOutputMessage,
    ShellStartMessage,
    emit_error,
    emit_info,
    emit_shell_line,
    emit_warning,
    get_message_bus,
)

# Hoisted imports - imported at module top for performance (CR-M4)
from code_puppy.security import get_security_boundary
from code_puppy.tools.common import generate_group_id, get_user_approval_async
from code_puppy.tools.subagent_context import is_subagent
from code_puppy.utils.file_display import truncate_with_guidance

# Lazy import for atexit - only used in _get_shell_executor (CR-M4)
try:
    import atexit

    _HAS_ATEXIT = True
except ImportError:
    _HAS_ATEXIT = False
    atexit = None  # type: ignore

# Cache for spinner module functions (lazy-loaded on first use)
_spinner_module_cache: dict[str, Callable | None] = {
    "pause_all_spinners": None,
    "resume_all_spinners": None,
}


def _get_spinner_func(name: str) -> Callable | None:
    """Get a spinner function from the spinner module, with caching."""
    if _spinner_module_cache[name] is None:
        try:
            from code_puppy.messaging import spinner

            _spinner_module_cache["pause_all_spinners"] = spinner.pause_all_spinners
            _spinner_module_cache["resume_all_spinners"] = spinner.resume_all_spinners
        except ImportError:
            return None
    return _spinner_module_cache[name]


# Absolute timeout for shell commands (seconds)
ABSOLUTE_TIMEOUT_SECONDS = 270

# Maximum line length for shell command output to prevent massive token usage
# This helps avoid exceeding model context limits when commands produce very long lines
MAX_LINE_LENGTH = 256

# Hint appended when a line is truncated (used by _truncate_line)
# This is exported for test assertions to avoid hardcoding the hint text
LINE_TRUNCATION_HINT = (
    "... [line truncated, command output too long, try filtering with grep]"
)

# Batch size for shell output emissions to reduce bus overhead
# Collects multiple lines and emits them together rather than one at a time
SHELL_BATCH_SIZE = 10


def _truncate_line(line: str) -> str:
    """Truncate a line to MAX_LINE_LENGTH if it exceeds the limit."""
    if len(line) > MAX_LINE_LENGTH:
        # ADOPT #6: Better truncation guidance for shell output
        return truncate_with_guidance(
            line, limit_chars=MAX_LINE_LENGTH, hint=LINE_TRUNCATION_HINT
        )
    return line


# =============================================================================
# SECURITY: Shell Command Validation
# =============================================================================
# Defense-in-depth: Even though upstream security (shell_safety plugin,
# policy engine, user confirmation) validates commands, we add an additional
# layer of protection at the execution point to prevent command injection.

# Maximum command length to prevent DoS via massive input
MAX_COMMAND_LENGTH = 8192

# Dangerous patterns that should be blocked even if upstream checks pass
# These patterns could indicate command injection attempts
DANGEROUS_PATTERNS = [
    # Process substitution (bash-specific, can be dangerous)
    r"<\s*\(",  # Input process substitution: <(command)
    r">\s*\(",  # Output process substitution: >(command)
    # Multiple redirections that could be abused
    r"\d*>&\d*\s*\d*>&",  # Multiple fd redirections
    # Null byte injection (can cause issues in some contexts)
    r"\x00",
]

# Characters that are NEVER allowed in commands (control characters, etc.)
# Using compiled regex for efficient validation (matches control chars except tab, LF, CR)
# Matches ASCII 0x00-0x08, 0x0B-0x0C, 0x0E-0x1F, and 0x7F (DEL)
_FORBIDDEN_CHARS_PATTERN = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")

# Compiled regex patterns for performance
# Using tuple instead of list for memory efficiency and immutability
_COMPILED_DANGEROUS_PATTERNS = tuple(re.compile(p) for p in DANGEROUS_PATTERNS)


class CommandValidationError(Exception):
    """Raised when a command fails security validation."""

    def __init__(self, reason: str, command: str | None = None):
        self.reason = reason
        self.command = command
        super().__init__(f"Command validation failed: {reason}")


def _validate_command_length(command: str) -> None:
    """Validate command length is within acceptable limits.

    Args:
        command: The command string to validate.

    Raises:
        CommandValidationError: If command exceeds MAX_COMMAND_LENGTH.
    """
    if len(command) > MAX_COMMAND_LENGTH:
        raise CommandValidationError(
            f"Command exceeds maximum length of {MAX_COMMAND_LENGTH} characters "
            f"(got {len(command)} characters)"
        )


def _validate_forbidden_chars(command: str) -> None:
    """Check for forbidden control characters in command.

    Args:
        command: The command string to validate.

    Raises:
        CommandValidationError: If forbidden characters are found.
    """
    matches = list(_FORBIDDEN_CHARS_PATTERN.finditer(command))
    if matches:
        found_chars = [
            f"0x{m.group()[0].encode('unicode_escape').decode('ascii')[:4]} at position {m.start()}"
            for m in matches[:5]
        ]
        # Format position info clearly
        found_chars = [
            f"0x{ord(m.group()):02x} at position {m.start()}" for m in matches[:5]
        ]
        raise CommandValidationError(
            f"Command contains forbidden control characters: {', '.join(found_chars)}"
            f"{' (and more...)' if len(matches) > 5 else ''}"
        )


def _validate_dangerous_patterns(command: str) -> None:
    """Check for dangerous shell patterns that could indicate injection.

    Args:
        command: The command string to validate.

    Raises:
        CommandValidationError: If dangerous patterns are detected.
    """
    for pattern in _COMPILED_DANGEROUS_PATTERNS:
        match = pattern.search(command)
        if match:
            # Show context around the match
            start = max(0, match.start() - 20)
            end = min(len(command), match.end() + 20)
            context = command[start:end]
            raise CommandValidationError(
                f"Command contains dangerous pattern near: '...{context}...'"
            )


def _validate_shlex_parse(command: str) -> None:
    """Validate command can be tokenized by shlex.

    This verifies the command string can be properly parsed (catches malformed
    quoting like unbalanced quotes, empty commands). This is NOT injection
    prevention - commands like "echo hi; uname -a" pass shlex validation fine.

    Args:
        command: The command string to validate.

    Raises:
        CommandValidationError: If shlex parsing fails or detects issues
            (unbalanced quotes, empty command, etc.).
    """
    try:
        # Attempt to parse the command with shlex
        # This validates proper quoting and tokenization ONLY
        # Does NOT catch: ; && || | > < $VAR * globs etc.
        tokens = shlex.split(command, posix=True)
        # shlex.split() already drops whitespace-only tokens, so just check if empty
        if not tokens:
            raise CommandValidationError(
                "Command contains no valid tokens after parsing"
            )
    except ValueError as e:
        raise CommandValidationError(
            f"Command parsing failed (possible malformed input): {e}"
        )


def validate_shell_command(command: str) -> str:
    """Validate a shell command for security issues before execution.

    This is a defense-in-depth measure. Commands are also validated upstream
    by the shell_safety plugin and policy engine, but we add an additional
    layer of protection at the execution point.

    Args:
        command: The shell command to validate.

    Returns:
        The validated command (unchanged if valid).

    Raises:
        CommandValidationError: If the command fails security validation.
    """
    if not command or not command.strip():
        raise CommandValidationError("Command cannot be empty or whitespace only")

    _validate_command_length(command)
    _validate_forbidden_chars(command)
    _validate_dangerous_patterns(command)
    _validate_shlex_parse(command)  # Additional layer: verify command can be parsed

    return command


# safe_execute_subprocess removed - was dead code (CR-L1 fix)
# Security validation and subprocess execution are handled directly
# in _run_command_sync with validate_shell_command() and subprocess.Popen


# =============================================================================
# Windows-specific: Check if pipe has data available without blocking
# =============================================================================
# This is needed because select() doesn't work on pipes on Windows
if sys.platform.startswith("win"):
    import msvcrt

    # Load kernel32 for PeekNamedPipe
    _kernel32 = ctypes.windll.kernel32

    def _win32_pipe_has_data(pipe) -> bool:
        """Check if a Windows pipe has data available without blocking.

        Uses PeekNamedPipe from kernel32.dll to check if there's data
        in the pipe buffer without actually reading it.

        Args:
            pipe: A file object with a fileno() method (e.g., process.stdout)

        Returns:
            True if data is available, False otherwise (including on error)
        """
        try:
            # Get the Windows handle from the file descriptor
            handle = msvcrt.get_osfhandle(pipe.fileno())

            # PeekNamedPipe parameters:
            # - hNamedPipe: handle to the pipe
            # - lpBuffer: buffer to receive data (NULL = don't read)
            # - nBufferSize: size of buffer (0 = don't read)
            # - lpBytesRead: receives bytes read (NULL)
            # - lpTotalBytesAvail: receives total bytes available
            # - lpBytesLeftThisMessage: receives bytes left (NULL)
            bytes_available = ctypes.c_ulong(0)

            result = _kernel32.PeekNamedPipe(
                handle,
                None,  # Don't read data
                0,  # Buffer size 0
                None,  # Don't care about bytes read
                ctypes.byref(bytes_available),  # Get bytes available
                None,  # Don't care about bytes left in message
            )

            if result:
                return bytes_available.value > 0
            return False
        except ValueError, OSError, ctypes.ArgumentError:
            # Handle closed, invalid, or other errors
            return False
else:
    # POSIX stub - not used, but keeps the code clean
    def _win32_pipe_has_data(pipe) -> bool:
        return False


# =============================================================================
# CONCURRENCY CONTROL
# =============================================================================
# This module uses a unified concurrency control approach:
#
# 1. CENTRALIZED SEMAPHORE (ToolCallsLimiter):
#    - From code_puppy.concurrency_limits
#    - Limits concurrent tool executions system-wide
#    - Applied at all shell command entry points (background + foreground)
#
# 2. THREADING LOCKS (for internal state protection):
#    All locks follow consistent naming: _<PURPOSE>_LOCK
#    - _CONFIRMATION_LOCK: Serializes interactive user confirmations
#    - _RUNNING_PROCESSES_LOCK: Protects process tracking set
#    - _KEYBOARD_CONTEXT_LOCK: Protects keyboard context refcount
#    - _ACTIVE_STOP_EVENTS_LOCK: Protects stop events registry
#    - _SHELL_EXECUTOR_LOCK: Thread-safe lazy executor init
#
# For cross-process or system-wide limits, ToolCallsLimiter is preferred.
# For internal state protection, threading.Lock is used with `with` statements.
# =============================================================================

_AWAITING_USER_INPUT = threading.Event()

# User confirmation lock - non-blocking acquire pattern for try-once semantics
_CONFIRMATION_LOCK = threading.Lock()

# Process tracking - protected by _RUNNING_PROCESSES_LOCK
_RUNNING_PROCESSES: set[subprocess.Popen] = set()
_RUNNING_PROCESSES_LOCK = threading.Lock()

# Bounded set of PIDs killed by user (dict as ordered set) - protected by _USER_KILLED_PROCESSES_LOCK
_USER_KILLED_PROCESSES: dict[int, None] = {}
_USER_KILLED_PROCESSES_LOCK = threading.Lock()
_USER_KILLED_PROCESSES_MAX = 1024

# Keyboard handling state (protected by _KEYBOARD_CONTEXT_LOCK where needed)
_SHELL_CTRL_X_STOP_EVENT: threading.Event | None = None
_SHELL_CTRL_X_THREAD: threading.Thread | None = None
_ORIGINAL_SIGINT_HANDLER = None
_KEYBOARD_CONTEXT_REFCOUNT = 0
_KEYBOARD_CONTEXT_LOCK = threading.Lock()

# Stop events registry - protected by _ACTIVE_STOP_EVENTS_LOCK
_ACTIVE_STOP_EVENTS: set[threading.Event] = set()
_ACTIVE_STOP_EVENTS_LOCK = threading.Lock()

# Thread pool executor - lazy-initialized, thread-safe via _SHELL_EXECUTOR_LOCK
_SHELL_EXECUTOR: ThreadPoolExecutor | None = None
_SHELL_EXECUTOR_LOCK = threading.Lock()


def _get_shell_executor() -> ThreadPoolExecutor:
    """Get or create the shell executor (lazy, thread-safe)."""
    global _SHELL_EXECUTOR
    if _SHELL_EXECUTOR is None:
        with _SHELL_EXECUTOR_LOCK:
            if _SHELL_EXECUTOR is None:  # double-check
                # CR-M4: atexit already imported at module top
                _SHELL_EXECUTOR = ThreadPoolExecutor(
                    max_workers=16,
                    thread_name_prefix="shell_cmd_",
                )
                if _HAS_ATEXIT and atexit:
                    # NOTE(audit-2026): wait=False is intentional — avoid blocking
                    # app exit. Orphaned subprocesses are an accepted trade-off
                    # vs. hanging on a long-running command at shutdown.
                    atexit.register(_SHELL_EXECUTOR.shutdown, wait=False)
    return _SHELL_EXECUTOR


def _register_process(proc: subprocess.Popen) -> None:
    with _RUNNING_PROCESSES_LOCK:
        _RUNNING_PROCESSES.add(proc)


def _unregister_process(proc: subprocess.Popen) -> None:
    with _RUNNING_PROCESSES_LOCK:
        _RUNNING_PROCESSES.discard(proc)


def _is_pid_in_killed_set(pid: int) -> bool:
    """Thread-safe check if a PID is in the killed processes set.

    Args:
        pid: Process ID to check.

    Returns:
        True if the PID was killed by user, False otherwise.
    """
    with _USER_KILLED_PROCESSES_LOCK:
        return pid in _USER_KILLED_PROCESSES


def _monitor_background_process(proc: subprocess.Popen) -> None:
    """Wait for background process to finish, then unregister it."""
    try:
        proc.wait()
    finally:
        _unregister_process(proc)


def _kill_process_group(proc: subprocess.Popen) -> None:
    """Attempt to aggressively terminate a process and its group.

    Cross-platform best-effort. On POSIX, uses process groups. On Windows, tries taskkill with /T flag for tree kill.
    Uses exponential backoff with Popen.wait(timeout=) instead of blocking time.sleep().
    """
    try:
        if sys.platform.startswith("win"):
            # On Windows, use taskkill to kill the process tree
            # /F = force, /T = kill tree (children), /PID = process ID
            try:
                import subprocess as sp

                # Try taskkill first - more reliable on Windows
                sp.run(
                    ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                    capture_output=True,
                    timeout=2,
                    check=False,
                )
                # Use wait with timeout instead of sleep (exponential budget: 0.3s)
                try:
                    proc.wait(timeout=0.3)
                    return
                except subprocess.TimeoutExpired:
                    pass
            except Exception:
                # Fallback to Python's built-in methods
                pass

            # Double-check it's dead, if not use proc.kill()
            if proc.poll() is None:
                try:
                    proc.kill()
                    # Use wait with timeout (exponential budget: 0.2s)
                    try:
                        proc.wait(timeout=0.2)
                    except subprocess.TimeoutExpired:
                        pass
                except Exception:
                    pass
            return

        # POSIX
        pid = proc.pid
        try:
            pgid = os.getpgid(pid)
            os.killpg(pgid, signal.SIGTERM)
            # Use wait with timeout (exponential budget: 1.0s -> 0.6s -> 0.5s -> 0.1s)
            try:
                proc.wait(timeout=1.0)
                return
            except subprocess.TimeoutExpired:
                pass
            if proc.poll() is None:
                os.killpg(pgid, signal.SIGINT)
                try:
                    proc.wait(timeout=0.6)
                except subprocess.TimeoutExpired:
                    pass
            if proc.poll() is None:
                os.killpg(pgid, signal.SIGKILL)
                try:
                    proc.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
        except OSError, ProcessLookupError:
            # Fall back to direct kill of the process
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError, ProcessLookupError:
                pass

        if proc.poll() is None:
            # Last ditch attempt; may be unkillable zombie
            try:
                for _ in range(3):
                    os.kill(proc.pid, signal.SIGKILL)
                    try:
                        proc.wait(timeout=0.1)  # Exponential budget: 0.1s
                        break
                    except subprocess.TimeoutExpired:
                        pass
            except Exception:
                pass
    except Exception as e:
        emit_error(f"Kill process error: {e}")


def _kill_single_process(p: subprocess.Popen) -> int:
    """Kill a single process and return 1 if it was killed, 0 otherwise.
    Helper for parallelized process killing."""
    try:
        # Close pipes first to unblock readline()
        try:
            if p.stdout and not p.stdout.closed:
                p.stdout.close()
            if p.stderr and not p.stderr.closed:
                p.stderr.close()
            if p.stdin and not p.stdin.closed:
                p.stdin.close()
        except OSError, ValueError:
            pass

        if p.poll() is None:
            _kill_process_group(p)
            # Thread-safe bounded add to prevent unbounded growth
            with _USER_KILLED_PROCESSES_LOCK:
                if len(_USER_KILLED_PROCESSES) >= _USER_KILLED_PROCESSES_MAX:
                    # Remove oldest entry (first key in insertion-ordered dict)
                    oldest_pid = next(iter(_USER_KILLED_PROCESSES))
                    del _USER_KILLED_PROCESSES[oldest_pid]
                _USER_KILLED_PROCESSES[p.pid] = None  # Use dict as ordered set
            return 1
    finally:
        _unregister_process(p)
    return 0


def kill_all_running_shell_processes() -> int:
    """Kill all currently tracked running shell processes and stop reader threads.

    Returns the number of processes signaled.
    Parallelizes kills across processes using ThreadPoolExecutor.
    """
    # Signal all active reader threads to stop
    with _ACTIVE_STOP_EVENTS_LOCK:
        for evt in _ACTIVE_STOP_EVENTS:
            evt.set()

    procs: list[subprocess.Popen]
    with _RUNNING_PROCESSES_LOCK:
        procs = list(_RUNNING_PROCESSES)

    if not procs:
        return 0

    # Parallelize kills across processes using ThreadPoolExecutor
    count = 0
    with ThreadPoolExecutor(max_workers=min(len(procs), 8)) as executor:
        futures = [executor.submit(_kill_single_process, p) for p in procs]
        for future in futures:
            count += future.result()
    return count


def get_running_shell_process_count() -> int:
    """Return the number of currently-active shell processes being tracked."""
    with _RUNNING_PROCESSES_LOCK:
        alive = 0
        stale: set[subprocess.Popen] = set()
        for proc in _RUNNING_PROCESSES:
            if proc.poll() is None:
                alive += 1
            else:
                stale.add(proc)
        for proc in stale:
            _RUNNING_PROCESSES.discard(proc)
    return alive


# Function to check if user input is awaited
def is_awaiting_user_input():
    """Check if command_runner is waiting for user input."""
    return _AWAITING_USER_INPUT.is_set()


# Function to set user input flag
def set_awaiting_user_input(awaiting=True):
    """Set the flag indicating if user input is awaited."""
    if awaiting:
        _AWAITING_USER_INPUT.set()
    else:
        _AWAITING_USER_INPUT.clear()

    # When we're setting this flag, also pause/resume all active spinners
    if awaiting:
        # Pause all active spinners using cached function
        pause_fn = _get_spinner_func("pause_all_spinners")
        if pause_fn:
            pause_fn()
    else:
        # Resume all active spinners using cached function
        resume_fn = _get_spinner_func("resume_all_spinners")
        if resume_fn:
            resume_fn()


class ShellCommandOutput(BaseModel):
    success: bool
    command: str | None = None
    error: str | None = ""
    stdout: str | None = None
    stderr: str | None = None
    exit_code: int | None = None
    execution_time: float | None = None
    timeout: bool | None = False
    user_interrupted: bool | None = False
    user_feedback: str | None = None  # User feedback when command is rejected
    background: bool = False  # True if command was run in background mode
    log_file: str | None = None  # Path to temp log file for background commands
    pid: int | None = None  # Process ID for background commands


class ShellSafetyAssessment(BaseModel):
    """Assessment of shell command safety risks.

    This model represents the structured output from the shell safety checker agent.
    It provides a risk level classification and reasoning for that assessment.

    Attributes:
        risk: Risk level classification. Can be one of:
              'none' (completely safe), 'low' (minimal risk), 'medium' (moderate risk),
              'high' (significant risk), 'critical' (severe/destructive risk).
        reasoning: Brief explanation (max 1-2 sentences) of why this risk level
                   was assigned. Should be concise and actionable.
        is_fallback: Whether this assessment is a fallback due to parsing failure.
                     Fallback assessments are not cached to allow retry with fresh LLM responses.
    """

    risk: Literal["none", "low", "medium", "high", "critical"]
    reasoning: str
    is_fallback: bool = False


def _listen_for_ctrl_x_windows(
    stop_event: threading.Event, on_escape: Callable[[], None]
) -> None:
    """Windows-specific Ctrl-X listener."""
    import msvcrt

    while not stop_event.is_set():
        try:
            if msvcrt.kbhit():
                try:
                    # Try to read a character
                    # Note: msvcrt.getwch() returns unicode string on Windows
                    key = msvcrt.getwch()

                    # Check for Ctrl+X (\x18) or other interrupt keys
                    # Some terminals might not send \x18, so also check for 'x' with modifier
                    if key == "\x18":  # Standard Ctrl+X
                        try:
                            on_escape()
                        except Exception:
                            emit_warning(
                                "Ctrl+X handler raised unexpectedly; Ctrl+C still works."
                            )
                    # Note: In some Windows terminals, Ctrl+X might not be captured
                    # Users can use Ctrl+C as alternative, which is handled by signal handler
                except OSError, ValueError:
                    # kbhit/getwch can fail on Windows in certain terminal states
                    # Just continue, user can use Ctrl+C
                    pass
        except Exception:
            # Be silent about Windows listener errors - they're common
            # User can use Ctrl+C as fallback
            pass
        # Reduced polling frequency: 0.1s instead of 0.05s to reduce CPU overhead
        time.sleep(0.1)


def _listen_for_ctrl_x_posix(
    stop_event: threading.Event, on_escape: Callable[[], None]
) -> None:
    """POSIX-specific Ctrl-X listener."""
    import select
    import sys
    import termios
    import tty

    stdin = sys.stdin
    try:
        fd = stdin.fileno()
    except AttributeError, ValueError, OSError:
        return
    try:
        original_attrs = termios.tcgetattr(fd)
    except Exception:
        return

    try:
        tty.setcbreak(fd)
        while not stop_event.is_set():
            try:
                # Reduced polling timeout: 0.1s instead of 0.05s to reduce CPU overhead
                read_ready, _, _ = select.select([stdin], [], [], 0.1)
            except Exception:
                break
            if not read_ready:
                continue
            data = stdin.read(1)
            if not data:
                break
            if data == "\x18":  # Ctrl+X
                try:
                    on_escape()
                except Exception:
                    emit_warning(
                        "Ctrl+X handler raised unexpectedly; Ctrl+C still works."
                    )
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original_attrs)


def _spawn_ctrl_x_key_listener(
    stop_event: threading.Event, on_escape: Callable[[], None]
) -> threading.Thread | None:
    """Start a Ctrl+X key listener thread for CLI sessions."""
    try:
        import sys
    except ImportError:
        return None

    stdin = getattr(sys, "stdin", None)
    if stdin is None or not hasattr(stdin, "isatty"):
        return None
    try:
        if not stdin.isatty():
            return None
    except Exception:
        return None

    def listener() -> None:
        try:
            if sys.platform.startswith("win"):
                _listen_for_ctrl_x_windows(stop_event, on_escape)
            else:
                _listen_for_ctrl_x_posix(stop_event, on_escape)
        except Exception:
            emit_warning(
                "Ctrl+X key listener stopped unexpectedly; press Ctrl+C to cancel."
            )

    thread = threading.Thread(
        target=listener, name="shell-command-ctrl-x-listener", daemon=True
    )
    thread.start()
    return thread


@contextmanager
def _shell_command_keyboard_context():
    """Context manager to handle keyboard interrupts during shell command execution.

    This context manager:
    1. Disables the agent's Ctrl-C handler (so it doesn't cancel the agent)
    2. Enables a Ctrl-X listener to kill the running shell process
    3. Restores the original Ctrl-C handler when done
    """
    global _SHELL_CTRL_X_STOP_EVENT, _SHELL_CTRL_X_THREAD, _ORIGINAL_SIGINT_HANDLER

    # Handler for Ctrl-X: kill all running shell processes
    def handle_ctrl_x_press() -> None:
        emit_warning("\n🛑 Ctrl-X detected! Interrupting shell command...")
        kill_all_running_shell_processes()

    # Handler for Ctrl-C during shell execution: just kill the shell process, don't cancel agent
    def shell_sigint_handler(_sig, _frame):
        """During shell execution, Ctrl-C kills the shell but doesn't cancel the agent."""
        emit_warning("\n🛑 Ctrl-C detected! Interrupting shell command...")
        kill_all_running_shell_processes()

    # Set up Ctrl-X listener
    _SHELL_CTRL_X_STOP_EVENT = threading.Event()
    _SHELL_CTRL_X_THREAD = _spawn_ctrl_x_key_listener(
        _SHELL_CTRL_X_STOP_EVENT, handle_ctrl_x_press
    )

    # Replace SIGINT handler temporarily
    try:
        _ORIGINAL_SIGINT_HANDLER = signal.signal(signal.SIGINT, shell_sigint_handler)
    except ValueError, OSError:
        # Can't set signal handler (maybe not main thread?)
        _ORIGINAL_SIGINT_HANDLER = None

    try:
        yield
    finally:
        # Clean up: stop Ctrl-X listener
        if _SHELL_CTRL_X_STOP_EVENT:
            _SHELL_CTRL_X_STOP_EVENT.set()

        if _SHELL_CTRL_X_THREAD and _SHELL_CTRL_X_THREAD.is_alive():
            try:
                _SHELL_CTRL_X_THREAD.join(timeout=0.2)
            except Exception:
                pass

        # Restore original SIGINT handler
        if _ORIGINAL_SIGINT_HANDLER is not None:
            try:
                signal.signal(signal.SIGINT, _ORIGINAL_SIGINT_HANDLER)
            except ValueError, OSError:
                pass

        # Clean up global state
        _SHELL_CTRL_X_STOP_EVENT = None
        _SHELL_CTRL_X_THREAD = None
        _ORIGINAL_SIGINT_HANDLER = None


def _handle_ctrl_x_press() -> None:
    """Handler for Ctrl-X: kill all running shell processes."""
    emit_warning("\n🛑 Ctrl-X detected! Interrupting all shell commands...")
    kill_all_running_shell_processes()


def _shell_sigint_handler(_sig, _frame):
    """During shell execution, Ctrl-C kills all shells but doesn't cancel agent."""
    emit_warning("\n🛑 Ctrl-C detected! Interrupting all shell commands...")
    kill_all_running_shell_processes()


def _start_keyboard_listener() -> None:
    """Start the Ctrl-X listener and install SIGINT handler.

    Called when the first shell command starts.
    """
    global _SHELL_CTRL_X_STOP_EVENT, _SHELL_CTRL_X_THREAD, _ORIGINAL_SIGINT_HANDLER

    # Set up Ctrl-X listener
    _SHELL_CTRL_X_STOP_EVENT = threading.Event()
    _SHELL_CTRL_X_THREAD = _spawn_ctrl_x_key_listener(
        _SHELL_CTRL_X_STOP_EVENT, _handle_ctrl_x_press
    )

    # Replace SIGINT handler temporarily
    try:
        _ORIGINAL_SIGINT_HANDLER = signal.signal(signal.SIGINT, _shell_sigint_handler)
    except ValueError, OSError:
        # Can't set signal handler (maybe not main thread?)
        _ORIGINAL_SIGINT_HANDLER = None


def _stop_keyboard_listener() -> None:
    """Stop the Ctrl-X listener and restore SIGINT handler.

    Called when the last shell command finishes.
    """
    global _SHELL_CTRL_X_STOP_EVENT, _SHELL_CTRL_X_THREAD, _ORIGINAL_SIGINT_HANDLER

    # Clean up: stop Ctrl-X listener
    if _SHELL_CTRL_X_STOP_EVENT:
        _SHELL_CTRL_X_STOP_EVENT.set()

    if _SHELL_CTRL_X_THREAD and _SHELL_CTRL_X_THREAD.is_alive():
        try:
            _SHELL_CTRL_X_THREAD.join(timeout=0.2)
        except Exception:
            pass

    # Restore original SIGINT handler
    if _ORIGINAL_SIGINT_HANDLER is not None:
        try:
            signal.signal(signal.SIGINT, _ORIGINAL_SIGINT_HANDLER)
        except ValueError, OSError:
            pass

    # Clean up global state
    _SHELL_CTRL_X_STOP_EVENT = None
    _SHELL_CTRL_X_THREAD = None
    _ORIGINAL_SIGINT_HANDLER = None


def _acquire_keyboard_context() -> None:
    """Acquire the shared keyboard context (reference counted).

    Starts the Ctrl-X listener when the first command starts.
    Safe to call from any thread.
    """
    global _KEYBOARD_CONTEXT_REFCOUNT

    should_start = False
    with _KEYBOARD_CONTEXT_LOCK:
        _KEYBOARD_CONTEXT_REFCOUNT += 1
        if _KEYBOARD_CONTEXT_REFCOUNT == 1:
            should_start = True

    # Start listener OUTSIDE the lock to avoid blocking other commands
    if should_start:
        _start_keyboard_listener()


def _release_keyboard_context() -> None:
    """Release the shared keyboard context (reference counted).

    Stops the Ctrl-X listener when the last command finishes.
    Safe to call from any thread.
    """
    global _KEYBOARD_CONTEXT_REFCOUNT

    should_stop = False
    with _KEYBOARD_CONTEXT_LOCK:
        _KEYBOARD_CONTEXT_REFCOUNT -= 1
        if _KEYBOARD_CONTEXT_REFCOUNT <= 0:
            _KEYBOARD_CONTEXT_REFCOUNT = 0  # Safety clamp
            should_stop = True

    # Stop listener OUTSIDE the lock to avoid blocking other commands
    if should_stop:
        _stop_keyboard_listener()


def run_shell_command_streaming(
    process: subprocess.Popen,
    timeout: int = 60,
    command: str = "",
    group_id: str = None,
    silent: bool = False,
):
    stop_event = threading.Event()
    with _ACTIVE_STOP_EVENTS_LOCK:
        _ACTIVE_STOP_EVENTS.add(stop_event)

    start_time = time.time()
    last_output_time = [start_time]

    stdout_lines = deque(maxlen=256)
    stderr_lines = deque(maxlen=256)

    # Buffers for batched shell line emissions
    # CR-L2 fix: batch with lock for thread-safe emission
    stdout_batch = []
    stderr_batch = []
    _batch_lock = threading.Lock()

    stdout_thread = None
    stderr_thread = None

    def _emit_stdout_batch():
        """Emit accumulated stdout lines as a batch.

        CR-L2 fix: Collect lines into buffer, acquire lock once,
        emit all buffered lines, release lock.
        """
        if silent:
            return
        # Capture under lock, emit outside lock
        lines_to_emit = None
        with _batch_lock:
            if stdout_batch:
                lines_to_emit = stdout_batch.copy()
                stdout_batch.clear()
        # Emit outside the lock to minimize lock contention
        if lines_to_emit:
            for line in lines_to_emit:
                emit_shell_line(line, stream="stdout")

    def _emit_stderr_batch():
        """Emit accumulated stderr lines as a batch.

        CR-L2 fix: Collect lines into buffer, acquire lock once,
        emit all buffered lines, release lock.
        """
        if silent:
            return
        # Capture under lock, emit outside lock
        lines_to_emit = None
        with _batch_lock:
            if stderr_batch:
                lines_to_emit = stderr_batch.copy()
                stderr_batch.clear()
        # Emit outside the lock to minimize lock contention
        if lines_to_emit:
            for line in lines_to_emit:
                emit_shell_line(line, stream="stderr")

    def _flush_all_batches():
        """Flush any remaining batched lines."""
        _emit_stdout_batch()
        _emit_stderr_batch()

    def read_stdout():
        try:
            fd = process.stdout.fileno()
        except ValueError, OSError:
            return

        try:
            while True:
                # Check stop event first
                if stop_event.is_set():
                    break

                # Use select to check if data is available (with timeout)
                if sys.platform.startswith("win"):
                    # Windows doesn't support select on pipes
                    # Use blocking readline() which waits for data efficiently
                    try:
                        line = process.stdout.readline()
                        if not line:  # EOF
                            # Process may have exited, do one final drain
                            if process.poll() is not None:
                                try:
                                    remaining = process.stdout.read()
                                    if remaining:
                                        lines_added = 0
                                        for ln in remaining.split("\n"):
                                            ln = _truncate_line(ln)
                                            stdout_lines.append(ln)
                                            if not silent:
                                                with _batch_lock:
                                                    stdout_batch.append(ln)
                                                    lines_added += 1
                                        if not silent and lines_added > 0:
                                            _emit_stdout_batch()
                                except ValueError, OSError:
                                    pass
                            break
                        line = line.rstrip("\n")
                        line = _truncate_line(line)
                        stdout_lines.append(line)
                        if not silent:
                            with _batch_lock:
                                stdout_batch.append(line)
                                should_emit = len(stdout_batch) >= SHELL_BATCH_SIZE
                            if should_emit:
                                _emit_stdout_batch()
                        last_output_time[0] = time.time()
                    except ValueError, OSError:
                        break
                else:
                    # POSIX: use select with timeout
                    try:
                        ready, _, _ = select.select([fd], [], [], 0.1)  # 100ms timeout
                    except ValueError, OSError, select.error:
                        break

                    if ready:
                        line = process.stdout.readline()
                        if not line:  # EOF
                            break
                        line = line.rstrip("\n")
                        line = _truncate_line(line)
                        stdout_lines.append(line)
                        if not silent:
                            with _batch_lock:
                                stdout_batch.append(line)
                                should_emit = len(stdout_batch) >= SHELL_BATCH_SIZE
                            if should_emit:
                                _emit_stdout_batch()
                        last_output_time[0] = time.time()
                    else:
                        # No data ready, use stop_event.wait() for efficient polling
                        if stop_event.wait(0.05):
                            break
        except ValueError, OSError:
            pass
        except Exception:
            pass
        finally:
            _emit_stdout_batch()

    def read_stderr():
        try:
            fd = process.stderr.fileno()
        except ValueError, OSError:
            return

        try:
            while True:
                # Check stop event first
                if stop_event.is_set():
                    break

                if sys.platform.startswith("win"):
                    # Windows doesn't support select on pipes
                    # Use blocking readline() which waits for data efficiently
                    try:
                        line = process.stderr.readline()
                        if not line:  # EOF
                            # Process may have exited, do one final drain
                            if process.poll() is not None:
                                try:
                                    remaining = process.stderr.read()
                                    if remaining:
                                        lines_added = 0
                                        for ln in remaining.split("\n"):
                                            ln = _truncate_line(ln)
                                            stderr_lines.append(ln)
                                            if not silent:
                                                with _batch_lock:
                                                    stderr_batch.append(ln)
                                                    lines_added += 1
                                        if not silent and lines_added > 0:
                                            _emit_stderr_batch()
                                except ValueError, OSError:
                                    pass
                            break
                        line = line.rstrip("\n")
                        line = _truncate_line(line)
                        stderr_lines.append(line)
                        if not silent:
                            with _batch_lock:
                                stderr_batch.append(line)
                                should_emit = len(stderr_batch) >= SHELL_BATCH_SIZE
                            if should_emit:
                                _emit_stderr_batch()
                        last_output_time[0] = time.time()
                    except ValueError, OSError:
                        break
                else:
                    try:
                        ready, _, _ = select.select([fd], [], [], 0.1)
                    except ValueError, OSError, select.error:
                        break

                    if ready:
                        line = process.stderr.readline()
                        if not line:  # EOF
                            break
                        line = line.rstrip("\n")
                        line = _truncate_line(line)
                        stderr_lines.append(line)
                        if not silent:
                            with _batch_lock:
                                stderr_batch.append(line)
                                should_emit = len(stderr_batch) >= SHELL_BATCH_SIZE
                            if should_emit:
                                _emit_stderr_batch()
                        last_output_time[0] = time.time()
                    else:
                        # No data ready, use stop_event.wait() for efficient polling
                        if stop_event.wait(0.05):
                            break
        except ValueError, OSError:
            pass
        except Exception:
            pass
        finally:
            _emit_stderr_batch()

    def cleanup_process_and_threads(timeout_type: str = "unknown"):
        nonlocal stdout_thread, stderr_thread

        def nuclear_kill(proc):
            _kill_process_group(proc)

        try:
            # Signal reader threads to stop first
            stop_event.set()

            if process.poll() is None:
                nuclear_kill(process)

            try:
                if process.stdout and not process.stdout.closed:
                    process.stdout.close()
                if process.stderr and not process.stderr.closed:
                    process.stderr.close()
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
            except OSError, ValueError:
                pass

            # Unregister once we're done cleaning up
            _unregister_process(process)

            if stdout_thread and stdout_thread.is_alive():
                stdout_thread.join(timeout=3)
                if stdout_thread.is_alive() and not silent:
                    emit_warning(
                        f"stdout reader thread failed to terminate after {timeout_type} timeout",
                        message_group=group_id,
                    )

            if stderr_thread and stderr_thread.is_alive():
                stderr_thread.join(timeout=3)
                if stderr_thread.is_alive() and not silent:
                    emit_warning(
                        f"stderr reader thread failed to terminate after {timeout_type} timeout",
                        message_group=group_id,
                    )

        except Exception as e:
            if not silent:
                emit_warning(
                    f"Error during process cleanup: {e}", message_group=group_id
                )

        execution_time = time.time() - start_time
        return ShellCommandOutput(
            **{
                "success": False,
                "command": command,
                # NOTE: direct join - deques are iterable and already maxlen=256
                "stdout": "\n".join(stdout_lines),
                "stderr": "\n".join(stderr_lines),
                "exit_code": -9,
                "execution_time": execution_time,
                "timeout": True,
                "error": f"Command timed out after {timeout} seconds",
            }
        )

    try:
        stdout_thread = threading.Thread(target=read_stdout, daemon=True)
        stderr_thread = threading.Thread(target=read_stderr, daemon=True)

        stdout_thread.start()
        stderr_thread.start()

        while process.poll() is None:
            current_time = time.time()

            if current_time - start_time > ABSOLUTE_TIMEOUT_SECONDS:
                if not silent:
                    emit_error(
                        "Process killed: absolute timeout reached",
                        message_group=group_id,
                    )
                return cleanup_process_and_threads("absolute")

            if current_time - last_output_time[0] > timeout:
                if not silent:
                    emit_error(
                        "Process killed: inactivity timeout reached",
                        message_group=group_id,
                    )
                return cleanup_process_and_threads("inactivity")

            time.sleep(0.1)

        if stdout_thread:
            stdout_thread.join(timeout=5)
        if stderr_thread:
            stderr_thread.join(timeout=5)

        exit_code = process.returncode
        execution_time = time.time() - start_time

        try:
            if process.stdout and not process.stdout.closed:
                process.stdout.close()
            if process.stderr and not process.stderr.closed:
                process.stderr.close()
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
        except OSError, ValueError:
            pass

        _unregister_process(process)

        # Apply line length limits to stdout/stderr before returning
        # NOTE: stdout_lines/stderr_lines are already deque(maxlen=256),
        # so no need for [-256:] slicing - str.join accepts deques natively (CR-M5)
        truncated_stdout = "\n".join(stdout_lines)
        truncated_stderr = "\n".join(stderr_lines)

        # Emit structured ShellOutputMessage for the UI (skip for silent sub-agents)
        if not silent:
            shell_output_msg = ShellOutputMessage(
                command=command,
                stdout=truncated_stdout,
                stderr=truncated_stderr,
                exit_code=exit_code,
                duration_seconds=execution_time,
            )
            get_message_bus().emit(shell_output_msg)

        with _ACTIVE_STOP_EVENTS_LOCK:
            _ACTIVE_STOP_EVENTS.discard(stop_event)

        if exit_code != 0:
            return ShellCommandOutput(
                success=False,
                command=command,
                error="""The process didn't exit cleanly! If the user_interrupted flag is true,
                please stop all execution and ask the user for clarification!""",
                stdout=truncated_stdout,
                stderr=truncated_stderr,
                exit_code=exit_code,
                execution_time=execution_time,
                timeout=False,
                user_interrupted=_is_pid_in_killed_set(process.pid),
            )

        return ShellCommandOutput(
            success=True,
            command=command,
            stdout=truncated_stdout,
            stderr=truncated_stderr,
            exit_code=exit_code,
            execution_time=execution_time,
            timeout=False,
        )

    except Exception as e:
        with _ACTIVE_STOP_EVENTS_LOCK:
            _ACTIVE_STOP_EVENTS.discard(stop_event)
        return ShellCommandOutput(
            success=False,
            command=command,
            error=f"Error during streaming execution: {str(e)}",
            # NOTE: direct join - deques are iterable and already maxlen=256
            stdout="\n".join(stdout_lines),
            stderr="\n".join(stderr_lines),
            exit_code=-1,
            execution_time=time.time() - start_time,
            timeout=False,
        )


async def run_shell_command(
    context: RunContext,
    command: str,
    cwd: str = None,
    timeout: int = 60,
    background: bool = False,
) -> ShellCommandOutput:
    # Generate unique group_id for this command execution
    group_id = generate_group_id("shell_command", command)

    # --- SecurityBoundary Integration (code_puppy-vdfn) ---
    # Centralized security enforcement: checks PolicyEngine rules and plugin callbacks
    # This replaces the manual callback triggering with a unified security interface
    # get_security_boundary is imported at module level for performance
    security = get_security_boundary()
    security_decision = await security.check_shell_command(
        command=command,
        cwd=cwd,
        timeout=timeout,
        context=context,
    )

    if not security_decision.allowed:
        return ShellCommandOutput(
            success=False,
            command=command,
            error=security_decision.reason or "Command blocked by security check",
            user_feedback=security_decision.reason,
            stdout=None,
            stderr=None,
            exit_code=None,
            execution_time=None,
        )

    # Handle background execution - runs command detached and returns immediately
    # This happens BEFORE user confirmation since we don't wait for the command
    if background:
        # SECURITY: Validate command BEFORE creating temp file to avoid resource leak
        # for invalid commands (defense-in-depth)
        try:
            validate_shell_command(command)
        except CommandValidationError as e:
            return ShellCommandOutput(
                success=False,
                command=command,
                error=f"Command validation failed: {e}",
                stdout=None,
                stderr=None,
                exit_code=None,
                execution_time=None,
                background=True,
            )

        # Respect centralized concurrency controls for background process spawning
        async with ToolCallsLimiter():
            # Create temp log file for output (only after validation passes)
            log_file = tempfile.NamedTemporaryFile(
                mode="w",
                prefix="shell_bg_",
                suffix=".log",
                delete=False,  # Keep file so agent can read it later
            )
            log_file_path = log_file.name

            try:
                # Platform-specific process detachment
                if sys.platform.startswith("win"):
                    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
                    process = subprocess.Popen(
                        command,
                        # nosec B602 - shell features required; risk managed by
                        # policy/user confirmation, dangerous-pattern blocking; shlex validates quoting only
                        shell=True,  # nosec B602
                        stdout=log_file,
                        stderr=subprocess.STDOUT,
                        stdin=subprocess.DEVNULL,
                        cwd=cwd,
                        creationflags=creationflags,
                    )
                else:
                    process = subprocess.Popen(
                        command,
                        # nosec B602 - shell features required; risk managed by
                        # policy/user confirmation, dangerous-pattern blocking; shlex validates quoting only
                        shell=True,  # nosec B602
                        stdout=log_file,
                        stderr=subprocess.STDOUT,
                        stdin=subprocess.DEVNULL,
                        cwd=cwd,
                        start_new_session=True,  # Fully detach on POSIX
                    )

                log_file.close()  # Close our handle, process keeps writing

                # Register background process for tracking (concurrency management)
                _register_process(process)

                # Start monitor thread to unregister when process exits (prevents memory leak)
                threading.Thread(
                    target=_monitor_background_process,
                    args=(process,),
                    daemon=True,
                    name=f"bg-monitor-{process.pid}",
                ).start()

                # Emit UI messages so user sees what happened
                bus = get_message_bus()
                bus.emit(
                    ShellStartMessage(
                        command=command,
                        cwd=cwd,
                        timeout=0,  # No timeout for background processes
                        background=True,
                    )
                )

                # Emit info about background execution
                emit_info(
                    f"🚀 Background process started (PID: {process.pid}) - no timeout, runs until complete"
                )
                emit_info(f"📄 Output logging to: {log_file.name}")

                # Return immediately - don't wait, don't block
                return ShellCommandOutput(
                    success=True,
                    command=command,
                    stdout=None,
                    stderr=None,
                    exit_code=None,
                    execution_time=0.0,
                    background=True,
                    log_file=log_file.name,
                    pid=process.pid,
                )
            except Exception as e:
                try:
                    log_file.close()
                except Exception:
                    pass
                # Clean up the temp file on error since no process will write to it
                try:
                    os.unlink(log_file_path)
                except OSError:
                    pass
                # Emit error message so user sees what happened
                emit_error(f"❌ Failed to start background process: {e}")
                return ShellCommandOutput(
                    success=False,
                    command=command,
                    error=f"Failed to start background process: {e}",
                    stdout=None,
                    stderr=None,
                    exit_code=None,
                    execution_time=None,
                    background=True,
                )

    # Rest of the existing function continues...
    if not command or not command.strip():
        emit_error("Command cannot be empty", message_group=group_id)
        return ShellCommandOutput(
            success=False,
            command=command,
            error="Command cannot be empty",
            stdout=None,
            stderr=None,
            exit_code=None,
            execution_time=None,
        )

    # get_yolo_mode is imported at module level for performance
    yolo_mode = get_yolo_mode()

    # Check if we're running as a sub-agent (skip confirmation and run silently)
    running_as_subagent = is_subagent()

    confirmation_lock_acquired = False

    # Only ask for confirmation if we're in an interactive TTY, not in yolo mode,
    # and NOT running as a sub-agent (sub-agents run without user interaction)
    if not yolo_mode and not running_as_subagent and sys.stdin.isatty():
        confirmation_lock_acquired = _CONFIRMATION_LOCK.acquire(blocking=False)
        if not confirmation_lock_acquired:
            return ShellCommandOutput(
                success=False,
                command=command,
                error="Another command is currently awaiting confirmation",
                stdout=None,
                stderr=None,
                exit_code=None,
                execution_time=None,
            )

        try:
            # Get puppy name for personalized messages
            # get_puppy_name is imported at module level for performance
            puppy_name = get_puppy_name().title()

            # Build panel content
            panel_content = Text()
            panel_content.append(
                "⚡ Requesting permission to run:\n", style="bold yellow"
            )
            panel_content.append("$ ", style="bold green")
            panel_content.append(command, style="bold white")

            if cwd:
                panel_content.append("\n\n", style="")
                panel_content.append("📂 Working directory: ", style="dim")
                panel_content.append(cwd, style="dim cyan")

            # Use the common approval function (async version)
            confirmed, user_feedback = await get_user_approval_async(
                title="Shell Command",
                content=panel_content,
                preview=None,
                border_style="dim white",
                puppy_name=puppy_name,
            )

            if not confirmed:
                if user_feedback:
                    result = ShellCommandOutput(
                        success=False,
                        command=command,
                        error=f"USER REJECTED: {user_feedback}",
                        user_feedback=user_feedback,
                        stdout=None,
                        stderr=None,
                        exit_code=None,
                        execution_time=None,
                    )
                else:
                    result = ShellCommandOutput(
                        success=False,
                        command=command,
                        error="User rejected the command!",
                        stdout=None,
                        stderr=None,
                        exit_code=None,
                        execution_time=None,
                    )
                return result
        finally:
            # Always release the lock to prevent deadlocks on exception
            if confirmation_lock_acquired:
                _CONFIRMATION_LOCK.release()

    # Execute the command - sub-agents run silently without keyboard context
    return await _execute_shell_command(
        command=command,
        cwd=cwd,
        timeout=timeout,
        group_id=group_id,
        silent=running_as_subagent,
    )


async def _execute_shell_command(
    command: str, cwd: str | None, timeout: int, group_id: str, silent: bool = False
) -> ShellCommandOutput:
    """Internal helper to execute a shell command.

    Args:
        command: The shell command to execute
        cwd: Working directory for command execution
        timeout: Inactivity timeout in seconds
        group_id: Unique group ID for message grouping
        silent: If True, suppress streaming output (for sub-agents)

    Returns:
        ShellCommandOutput with execution results
    """
    # Always emit the ShellStartMessage banner (even for sub-agents)
    bus = get_message_bus()
    bus.emit(ShellStartMessage(command=command, cwd=cwd, timeout=timeout))

    # Pause spinner during shell command so \r output can work properly
    # Using cached spinner functions for performance
    pause_fn = _get_spinner_func("pause_all_spinners")
    resume_fn = _get_spinner_func("resume_all_spinners")
    if pause_fn:
        pause_fn()

    # Acquire shared keyboard context - Ctrl-X/Ctrl-C will kill ALL running commands
    # This is reference-counted: listener starts on first command, stops on last
    _acquire_keyboard_context()
    try:
        # Respect centralized concurrency controls for tool calls
        async with ToolCallsLimiter():
            return await _run_command_inner(
                command, cwd, timeout, group_id, silent=silent
            )
    finally:
        _release_keyboard_context()
        if resume_fn:
            resume_fn()


def _run_command_sync(
    command: str, cwd: str | None, timeout: int, group_id: str, silent: bool = False
) -> ShellCommandOutput:
    """Synchronous command execution - runs in thread pool."""
    creationflags = 0
    preexec_fn = None
    process_group = None
    if sys.platform.startswith("win"):
        try:
            creationflags = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
        except Exception:
            creationflags = 0
    else:
        # CR-L3 fix: Use process_group=0 for Python 3.11+ (faster, uses posix_spawn)
        # Fallback to preexec_fn=os.setsid for older Python versions
        if _sys.version_info >= (3, 11):
            process_group = 0  # Modern way: posix_spawn with process group
        else:
            preexec_fn = os.setsid if hasattr(os, "setsid") else None  # Legacy way

    # SECURITY: Validate command before execution (defense-in-depth)
    try:
        validate_shell_command(command)
    except CommandValidationError as e:
        return ShellCommandOutput(
            success=False,
            command=command,
            error=f"Security validation failed: {e.reason}",
            stdout=None,
            stderr=None,
            exit_code=-1,
            execution_time=0.0,
        )

    # Build Popen kwargs - only include process_group on Python 3.11+
    popen_kwargs = dict(
        shell=True,  # nosec B602 - shell features required; risk managed by policy
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        bufsize=-1,  # Use default buffering
        creationflags=creationflags,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if process_group is not None:
        popen_kwargs["process_group"] = process_group
    elif preexec_fn is not None:
        popen_kwargs["preexec_fn"] = preexec_fn

    process = subprocess.Popen(command, **popen_kwargs)
    _register_process(process)
    try:
        return run_shell_command_streaming(
            process, timeout=timeout, command=command, group_id=group_id, silent=silent
        )
    finally:
        # Ensure unregistration in case streaming returned early or raised
        _unregister_process(process)


async def _run_command_inner(
    command: str, cwd: str | None, timeout: int, group_id: str, silent: bool = False
) -> ShellCommandOutput:
    """Inner command execution logic - runs blocking code in thread pool."""
    loop = asyncio.get_running_loop()
    try:
        # Run the blocking shell command in a thread pool to avoid blocking the event loop
        # This allows multiple sub-agents to run shell commands in parallel
        return await loop.run_in_executor(
            _get_shell_executor(),
            partial(_run_command_sync, command, cwd, timeout, group_id, silent),
        )
    except Exception as e:
        if not silent:
            emit_error(traceback.format_exc(), message_group=group_id)
        if "stdout" not in locals():
            stdout = None
        if "stderr" not in locals():
            stderr = None

        # Apply line length limits to stdout/stderr if they exist
        # CR-M5 fix: No need for list()[-256:] slicing - just truncate last 256 lines
        truncated_stdout = None
        if stdout:
            stdout_lines = stdout.split("\n")
            # Take last 256 lines (no-op if fewer), truncate each, join
            truncated_stdout = "\n".join(
                [_truncate_line(line) for line in stdout_lines[-256:]]
            )

        truncated_stderr = None
        if stderr:
            stderr_lines = stderr.split("\n")
            # Take last 256 lines (no-op if fewer), truncate each, join
            truncated_stderr = "\n".join(
                [_truncate_line(line) for line in stderr_lines[-256:]]
            )

        return ShellCommandOutput(
            success=False,
            command=command,
            error=f"Error executing command {str(e)}",
            stdout=truncated_stdout,
            stderr=truncated_stderr,
            exit_code=-1,
            execution_time=None,
            timeout=False,
        )


class ReasoningOutput(BaseModel):
    success: bool = True


def share_your_reasoning(
    context: RunContext, reasoning: str, next_steps: str | list[str] | None = None
) -> ReasoningOutput:
    # Handle list of next steps by formatting them
    formatted_next_steps = next_steps
    if isinstance(next_steps, list):
        formatted_next_steps = "\n".join(
            [f"{i + 1}. {step}" for i, step in enumerate(next_steps)]
        )

    # Emit structured AgentReasoningMessage for the UI
    reasoning_msg = AgentReasoningMessage(
        reasoning=reasoning,
        next_steps=formatted_next_steps
        if formatted_next_steps and formatted_next_steps.strip()
        else None,
    )
    get_message_bus().emit(reasoning_msg)

    return ReasoningOutput(success=True)


def register_agent_run_shell_command(agent):
    """Register only the agent_run_shell_command tool."""

    @agent.tool
    async def agent_run_shell_command(
        context: RunContext,
        command: str = "",
        cwd: str = None,
        timeout: int = 60,
        background: bool = False,
    ) -> ShellCommandOutput:
        """Execute a shell command with comprehensive monitoring and safety features.

        Supports streaming output, timeout handling, and background execution.
        """
        return await run_shell_command(context, command, cwd, timeout, background)


def register_agent_share_your_reasoning(agent):
    """Register only the agent_share_your_reasoning tool."""

    @agent.tool
    def agent_share_your_reasoning(
        context: RunContext,
        reasoning: str = "",
        next_steps: str | list[str] | None = None,
    ) -> ReasoningOutput:
        """Share the agent's current reasoning and planned next steps with the user.

        Displays reasoning and upcoming actions in a formatted panel for transparency.
        """
        return share_your_reasoning(context, reasoning, next_steps)
