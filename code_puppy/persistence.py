"""Safe atomic persistence helpers for file operations.

This module provides atomic file write operations to prevent partial/corrupt
files on crash or interruption. All writes use temp-file + atomic replace.
"""

import asyncio
import contextlib
import json
import logging
import os
import tempfile
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Cache of directories that have already been created to avoid redundant mkdir calls
_created_dirs: set[Path] = set()
_created_dirs_lock = threading.Lock()


def _check_isolation_guard(path: Path) -> None:
    """Check ADR-003 isolation guard for writes targeting config-home paths.

    This is a belt-and-suspenders check: if the target path is under a
    config home directory (``~/.code_puppy/`` or ``~/.code_puppy_ex/``),
    we delegate to the config_paths module's isolation guard.  For paths
    outside these directories (e.g. project files), the check is skipped.

    **Canonical resolution** is used so that symlinks whose lexical path
    is outside the config home but whose real target is inside are still
    caught (and vice-versa).  This blocks the bypass where a non-home
    lexical path is symlinked into the legacy home.

    This design avoids a hard dependency on the config_paths module for
    all persistence operations while still catching config-home writes.

    Raises:
        ConfigIsolationViolation: If the write would violate isolation.
    """
    try:
        from code_puppy.config_paths import (
            _canonical,
            assert_write_allowed,
            home_dir,
            legacy_home_dir,
        )

        # Use CANONICAL (realpath) comparison so symlinks are resolved
        # before the prefix check.  This prevents bypasses where a lexical
        # non-home path is symlinked into a config home.
        path_canonical = _canonical(path)
        for home_fn in (legacy_home_dir, home_dir):
            home_canonical = _canonical(home_fn())
            if path_canonical == home_canonical or path_canonical.startswith(
                home_canonical + os.sep
            ):
                assert_write_allowed(path, "atomic_write")
                return
    except ImportError:
        # config_paths module not available yet — skip guard
        pass
    except Exception as e:
        # Let ConfigIsolationViolation propagate — this is an intentional block
        from code_puppy.config_paths import ConfigIsolationViolation

        if isinstance(e, ConfigIsolationViolation):
            raise
        # Defensive: never block a write due to a guard bug
        logger.debug("isolation guard check failed for %s", path, exc_info=True)


def safe_resolve_path(path: Path, allowed_parent: Path | None = None) -> Path:
    """Resolve path to absolute and optionally verify it's within allowed_parent.

    Uses os.path.normpath to normalize '..' components without following symlinks,
    preventing path traversal attacks while avoiding TOCTOU (Time-of-Check-Time-of-Use)
    race conditions that could occur with symlink resolution.

    Args:
        path: The path to resolve
        allowed_parent: Optional parent directory that path must be within

    Returns:
        Resolved absolute path with normalized '..' components (lexical resolution only)

    Raises:
        ValueError: If path resolves outside allowed_parent
        OSError: If path resolution fails
    """
    try:
        # Use os.path.normpath to collapse '..' without following symlinks (avoids TOCTOU)
        resolved = Path(os.path.normpath(path.absolute()))
    except (OSError, RuntimeError) as e:
        raise OSError(f"Failed to resolve path {path}: {e}") from e

    if allowed_parent is not None:
        try:
            resolved.relative_to(Path(os.path.normpath(allowed_parent.absolute())))
        except ValueError:
            raise ValueError(
                f"Path {resolved} is outside allowed parent {allowed_parent}"
            )

    return resolved


def _ensure_parent_dir(path: Path) -> None:
    """Ensure parent directory exists, using cache to avoid redundant mkdir calls."""
    parent = path.parent
    with _created_dirs_lock:
        if parent in _created_dirs:
            return
        if parent.exists():
            _created_dirs.add(parent)
            return
        parent.mkdir(parents=True, exist_ok=True)
        _created_dirs.add(parent)


def _atomic_replace(tmp_path: Path, target_path: Path) -> None:
    """Atomically replace target with tmp file.

    Handles cross-platform differences in atomic rename.
    """
    # Ensure parent directory exists
    _ensure_parent_dir(target_path)

    # On Windows, replace may fail if target is open; we accept that risk
    # On Unix, this is truly atomic
    tmp_path.replace(target_path)


def atomic_write_text(path: Path, content: str, encoding: str = "utf-8") -> None:
    """Write text file atomically using temp file + replace.

    Args:
        path: Target file path
        content: Text content to write
        encoding: Text encoding (default: utf-8)

    Raises:
        OSError: If write fails
        ConfigIsolationViolation: If path is outside the active home (pup-ex mode)
    """
    path = safe_resolve_path(path)

    # ADR-003: Check isolation guard for config-home paths
    _check_isolation_guard(path)

    # Ensure parent directory exists (cached to avoid redundant calls)
    _ensure_parent_dir(path)

    # Create temp file in same directory for atomic move
    fd = None
    tmp_path = None
    try:
        fd, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)

        with open(fd, "w", encoding=encoding) as f:
            f.write(content)

        _atomic_replace(tmp_path, path)

    except Exception:
        # Clean up temp file on any error
        if tmp_path is not None:
            with contextlib.suppress(Exception):
                tmp_path.unlink(missing_ok=True)
        raise


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Write binary file atomically using temp file + replace.

    Args:
        path: Target file path
        data: Binary data to write

    Raises:
        OSError: If write fails
    """
    path = safe_resolve_path(path)

    # Ensure parent directory exists (cached to avoid redundant calls)
    _ensure_parent_dir(path)

    fd = None
    tmp_path = None
    try:
        fd, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)

        with open(fd, "wb") as f:
            f.write(data)

        _atomic_replace(tmp_path, path)

    except Exception:
        if tmp_path is not None:
            with contextlib.suppress(Exception):
                tmp_path.unlink(missing_ok=True)
        raise


def atomic_write_json(
    path: Path | str,
    data: Any,
    indent: int = 2,
    default: Callable[[Any], Any] | None = None,
) -> None:
    """Write JSON file atomically.

    Args:
        path: Target file path
        data: JSON-serializable data
        indent: JSON indentation (default: 2)
        default: Optional JSON serializer for custom types

    Raises:
        OSError: If write fails
        TypeError: If data is not JSON-serializable
    """
    path_obj = Path(path)

    try:
        content = json.dumps(data, indent=indent, default=default)
        atomic_write_text(path_obj, content)
    except (TypeError, ValueError) as e:
        raise TypeError(f"Data is not JSON-serializable: {e}") from e


def atomic_write_msgpack(
    path: Path, data: Any, default: Callable[[Any], Any] | None = None
) -> None:
    """Write JSON file atomically (binary output).

    Historical name kept for API compatibility. Now uses stdlib json
    instead of msgpack for free-threaded Python compatibility.

    Args:
        path: Target file path
        data: JSON-serializable data
        default: Optional serializer for custom types

    Raises:
        OSError: If write fails
        TypeError: If data is not JSON-serializable
    """
    try:
        packed = json.dumps(data, separators=(",", ":"), default=default or str).encode(
            "utf-8"
        )
    except (TypeError, ValueError) as e:
        raise TypeError(f"Data is not JSON-serializable: {e}") from e

    atomic_write_bytes(path, packed)


def read_json(path: Path, default: Any = None) -> Any:
    """Read JSON file safely.

    Args:
        path: File path to read
        default: Value to return if file doesn't exist or is invalid

    Returns:
        Parsed JSON data or default value
    """
    path = safe_resolve_path(path)

    if not path.exists():
        return default

    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError, ValueError) as e:
        logger.warning(f"Failed to read JSON from {path}: {e}")
        return default


def read_msgpack(path: Path, default: Any = None) -> Any:
    """Read JSON file safely.

    Historical name kept for API compatibility. Now uses stdlib json
    instead of msgpack for free-threaded Python compatibility.

    Args:
        path: File path to read
        default: Value to return if file doesn't exist or is invalid

    Returns:
        Parsed data or default value
    """
    path = safe_resolve_path(path)

    if not path.exists():
        return default

    try:
        raw = path.read_bytes()
        return json.loads(raw)
    except (json.JSONDecodeError, OSError, ValueError) as e:
        logger.warning(f"Failed to read data from {path}: {e}")
        return default


# ----- Async wrappers using asyncio.to_thread -----


async def atomic_write_text_async(
    path: Path, content: str, encoding: str = "utf-8"
) -> None:
    """Async wrapper for atomic_write_text using asyncio.to_thread.

    Args:
        path: Target file path
        content: Text content to write
        encoding: Text encoding (default: utf-8)
    """
    await asyncio.to_thread(atomic_write_text, path, content, encoding)


async def atomic_write_bytes_async(path: Path, data: bytes) -> None:
    """Async wrapper for atomic_write_bytes using asyncio.to_thread.

    Args:
        path: Target file path
        data: Binary data to write
    """
    await asyncio.to_thread(atomic_write_bytes, path, data)


async def atomic_write_msgpack_async(
    path: Path, data: Any, default: Callable[[Any], Any] | None = None
) -> None:
    """Async wrapper for atomic_write_msgpack using asyncio.to_thread.

    Args:
        path: Target file path
        data: JSON-serializable data
        default: Optional serializer for custom types
    """
    await asyncio.to_thread(atomic_write_msgpack, path, data, default)


async def read_json_async(path: Path, default: Any = None) -> Any:
    """Async wrapper for read_json using asyncio.to_thread.

    Args:
        path: File path to read
        default: Value to return if file doesn't exist or is invalid

    Returns:
        Parsed JSON data or default value
    """
    return await asyncio.to_thread(read_json, path, default)


async def read_msgpack_async(path: Path, default: Any = None) -> Any:
    """Async wrapper for read_msgpack using asyncio.to_thread.

    Args:
        path: File path to read
        default: Value to return if file doesn't exist or is invalid

    Returns:
        Parsed JSON data or default value
    """
    return await asyncio.to_thread(read_msgpack, path, default)
