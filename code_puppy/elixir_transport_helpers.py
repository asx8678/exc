"""
Convenience functions and singleton for the Elixir transport client.

This module provides module-level convenience functions for simple
use cases that don't need explicit transport management.

## Usage

```python
from code_puppy import elixir_transport_helpers as elixir

# List files
files = elixir.list_files(".", recursive=True)

# Read a file
result = elixir.read_file("path/to/file.py")
print(result["content"])

# Search in files
matches = elixir.grep("def ", ".")

# Cleanup when done
elixir.shutdown()
```

For advanced use cases with explicit control, use the ElixirTransport class directly:

```python
from code_puppy.elixir_transport import ElixirTransport

with ElixirTransport() as transport:
    files = transport.list_files(".")
```

## Environment Variables

- `PUP_ELIXIR_PATH` - Path to elixir/mix executable directory
- `PUP_ELIXIR_SERVICE_CMD` - Override the command to start the service
- `PUP_LOG_LEVEL` - Set Elixir service log level (debug, info, warn, error)
"""

import logging
import threading
from typing import Any

logger = logging.getLogger(__name__)


# Module-level singleton for simple use cases
_module_transport: Any = None

# Threading lock for double-checked locking pattern
_module_transport_lock = threading.Lock()


# Backward compatibility alias
def _get_transport() -> "ElixirTransport":  # type: ignore # noqa: F821
    """Get or create the module-level transport singleton (backward compatibility alias)."""
    return get_transport()


def _transport_is_alive(transport) -> bool:
    """Check whether a cached transport's BEAM process is still running.

    Returns False if transport is None, its process was never started,
    or the process has exited. Safe to call from any thread without
    holding _module_transport_lock (Popen.poll() is thread-safe).
    """
    if transport is None:
        return False
    try:
        return transport.is_alive()
    except Exception:
        # Defensive: if is_alive() itself fails, treat as dead
        return False


def get_transport() -> "ElixirTransport":  # type: ignore # noqa: F821
    """Get or create the module-level transport singleton.

    If the previously cached transport's BEAM process has died, this function
    logs a warning, discards the dead singleton, and attempts to start a fresh
    one.

    Thread-safe under free-threaded Python (3.13+ with GIL disabled):
    only a fully-started transport is ever published to the module-level
    variable. If startup fails, the exception propagates and no partial
    transport is cached.
    """
    global _module_transport

    # Fast path: cached transport exists and is alive
    if _module_transport is not None and _transport_is_alive(_module_transport):
        return _module_transport

    with _module_transport_lock:
        # Re-check under lock (double-checked locking)
        if _module_transport is not None:
            if _transport_is_alive(_module_transport):
                return _module_transport

            # Transport died between the probe and now — discard and restart
            logger.warning(
                "Elixir transport process died; discarding stale singleton "
                "and attempting restart"
            )
            try:
                _module_transport.stop()
            except Exception:
                pass
            _module_transport = None

        from code_puppy.elixir_transport import ElixirTransport

        t = ElixirTransport()
        t.start()  # may raise; if so, _module_transport stays None
        _module_transport = t  # publish only after successful start
        return _module_transport


def list_files(
    directory: str = ".",
    recursive: bool = True,
    include_hidden: bool = False,
    ignore_patterns: list[str] | None = None,
    max_files: int = 10_000,
) -> list[dict[str, Any]]:
    """Module-level convenience function to list files.

    Args:
        directory: Path to list
        recursive: Whether to recurse into subdirectories
        include_hidden: Whether to include hidden files
        ignore_patterns: List of glob patterns to ignore
        max_files: Maximum number of files to return

    Returns:
        List of file info dicts with path, type, size, modified fields

    Example:
        >>> files = list_files("src", recursive=True)
        >>> print([f["path"] for f in files])
    """
    return get_transport().list_files(
        directory, recursive, include_hidden, ignore_patterns, max_files
    )


def read_file(
    path: str,
    start_line: int | None = None,
    num_lines: int | None = None,
) -> dict[str, Any]:
    """Module-level convenience function to read a file.

    Args:
        path: Path to the file
        start_line: 1-based starting line number (optional)
        num_lines: Maximum number of lines to read (optional)

    Returns:
        Dict with path, content, num_lines, size, truncated, error fields

    Example:
        >>> result = read_file("README.md", num_lines=50)
        >>> print(result["content"])
    """
    return get_transport().read_file(path, start_line, num_lines)


def read_files(
    paths: list[str],
    start_line: int | None = None,
    num_lines: int | None = None,
) -> list[dict[str, Any]]:
    """Module-level convenience function to read multiple files.

    Args:
        paths: List of file paths
        start_line: 1-based starting line number (optional)
        num_lines: Maximum number of lines to read (optional)

    Returns:
        List of file result dicts

    Example:
        >>> results = read_files(["a.py", "b.py"])
        >>> for r in results:
        ... print(r["path"], len(r["content"]))
    """
    return get_transport().read_files(paths, start_line, num_lines)


def grep(
    pattern: str,
    directory: str = ".",
    case_sensitive: bool = True,
    max_matches: int = 1_000,
    file_pattern: str = "*",
    context_lines: int = 0,
) -> list[dict[str, Any]]:
    """Module-level convenience function to search files.

    Args:
        pattern: Regex pattern to search for
        directory: Directory to search in
        case_sensitive: Whether the search is case-sensitive
        max_matches: Maximum number of matches to return
        file_pattern: Glob pattern to filter files
        context_lines: Number of context lines around matches

    Returns:
        List of match dicts with file, line_number, line_content,
        match_start, match_end

    Example:
        >>> matches = grep(r"def ", "src/")
        >>> for m in matches[:5]:
        ... print(f"{m['file']}:{m['line_number']}: {m['line_content']}")
    """
    return get_transport().grep(
        pattern, directory, case_sensitive, max_matches, file_pattern, context_lines
    )


def ping() -> dict[str, Any]:
    """Send a ping to check if the service is responsive.

    Returns:
        Dict with "pong" and "timestamp" fields
    """
    return get_transport().ping()


def health_check() -> dict[str, Any]:
    """Get detailed health status from the service.

    Returns:
        Dict with status, version, elixir_version, otp_version, timestamp
    """
    return get_transport().health_check()


def shutdown() -> None:
    """Shutdown the module-level transport singleton.

    Call this when you're done using the module-level convenience functions
    to properly clean up resources.

    Example:
        >>> files = list_files(".")
        >>> shutdown()
    """
    global _module_transport
    # Swap out under lock, stop outside lock to avoid holding it during I/O.
    # Tradeoff: another thread could call get_transport() and start a new
    # transport before we stop the old one, but that's acceptable since
    # we guarantee the returned transport is always in a started state.
    with _module_transport_lock:
        local = _module_transport
        _module_transport = None
    if local is not None:
        local.stop()
