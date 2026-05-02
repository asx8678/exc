"""Per-file async lock for serializing concurrent mutations.

Ported from pi-mono-main's file-mutation-queue.ts (37-line promise-chaining
pattern). Adapted to Python asyncio.Lock primitives.

Different files run concurrently; the same file (by realpath) is serialized.
"""

import asyncio
import os
import threading
from contextlib import asynccontextmanager, contextmanager
from typing import Generator

__all__ = ["file_lock", "file_lock_sync", "active_lock_count"]

# Map of realpath -> asyncio.Lock. Use a regular dict, not WeakValueDictionary,
# because Lock objects need to persist while waiters exist.
_locks: dict[str, asyncio.Lock] = {}
_meta_lock = asyncio.Lock()  # Protects _locks dict mutations

# Sync version for threaded code
_sync_locks: dict[str, threading.Lock] = {}
_sync_meta_lock = threading.Lock()


def _resolve_key(file_path: str) -> str:
    """Canonicalize path via realpath for symlink-safe keying.

    Args:
        file_path: Path to resolve (absolute or relative).

    Returns:
        Realpath if available, otherwise abspath on OSError.
    """
    resolved = os.path.abspath(file_path)
    try:
        return os.path.realpath(resolved)
    except OSError:
        return resolved


@asynccontextmanager
async def file_lock(file_path: str) -> Generator[None, None, None]:
    """Async context manager that serializes access to the same file.

    Usage:
        async with file_lock("/path/to/file.py"):
            # Only one coroutine at a time for this file
            await do_write(...)

    Different file paths run concurrently. Same realpath is serialized.

    Args:
        file_path: Path to the file to lock (symlinks resolved to realpath).

    Yields:
        None when the lock is acquired.
    """
    key = _resolve_key(file_path)

    async with _meta_lock:
        if key not in _locks:
            _locks[key] = asyncio.Lock()
        lock = _locks[key]

    await lock.acquire()
    try:
        yield
    finally:
        lock.release()
        # Clean up lock if no one is waiting
        async with _meta_lock:
            # Check if key still exists and is unlocked
            if key in _locks and not _locks[key].locked():
                # Check no waiters - if the lock is not locked and we just released,
                # it's safe to remove (no one is waiting)
                del _locks[key]


@contextmanager
def file_lock_sync(file_path: str) -> Generator[None, None, None]:
    """Thread-safe sync context manager for use in sync code paths.

    Usage:
        with file_lock_sync("/path/to/file.py"):
            # Only one thread at a time for this file
            do_write(...)

    Different file paths run concurrently. Same realpath is serialized.

    Args:
        file_path: Path to the file to lock (symlinks resolved to realpath).

    Yields:
        None when the lock is acquired.
    """
    key = _resolve_key(file_path)
    with _sync_meta_lock:
        if key not in _sync_locks:
            _sync_locks[key] = threading.Lock()
        lock = _sync_locks[key]

    lock.acquire()
    try:
        yield
    finally:
        lock.release()
        with _sync_meta_lock:
            if key in _sync_locks and not _sync_locks[key].locked():
                del _sync_locks[key]


def active_lock_count() -> int:
    """Return the number of currently tracked file locks (for testing/monitoring)."""
    return len(_locks)


# ===========================================================================
# Cross-process file locking (directory-based)
#
# Ported from oh-my-pi's file-lock.ts pattern.
# Uses mkdir-based atomic lock acquisition with stale lock detection
# via PID liveness and timestamp.  Works cross-platform (unlike fcntl.flock).
# ===========================================================================

_CROSS_PROCESS_STALE_MS = 10_000  # 10 seconds default stale threshold
_CROSS_PROCESS_RETRIES = 50
_CROSS_PROCESS_RETRY_DELAY = 0.1  # seconds

__all__ = [
    "file_lock",
    "file_lock_sync",
    "active_lock_count",
    "cross_process_file_lock",
    "cross_process_file_lock_sync",
]


def _lock_dir_path(file_path: str) -> str:
    """Get the lock directory path for a file."""
    return f"{os.path.abspath(file_path)}.lock"


def _write_lock_info(lock_dir: str) -> None:
    """Write PID and timestamp info into the lock directory."""
    import json
    import time

    info = {"pid": os.getpid(), "timestamp": time.time()}
    info_path = os.path.join(lock_dir, "info")
    try:
        with open(info_path, "w") as f:
            json.dump(info, f)
    except OSError:
        pass


def _read_lock_info(lock_dir: str) -> dict | None:
    """Read lock info from the lock directory."""
    import json

    info_path = os.path.join(lock_dir, "info")
    try:
        with open(info_path, "r") as f:
            return json.load(f)
    except OSError, json.JSONDecodeError, ValueError:
        return None


def _is_process_alive(pid: int) -> bool:
    """Check if a process is still running."""
    try:
        os.kill(pid, 0)
        return True
    except OSError, ProcessLookupError:
        return False


def _is_lock_stale(
    lock_dir: str, stale_ms: int, *, max_retries: int = 3, retry_delay: float = 0.01
) -> bool:
    """Check if an existing lock is stale.

    A lock is stale if:
    - The lock info file cannot be read after retries
    - The owning process is no longer alive
    - The lock is older than stale_ms milliseconds

    Args:
        lock_dir: Path to the lock directory.
        stale_ms: Time in ms after which a lock is considered stale.
        max_retries: Number of retries if info file is missing (race condition handling).
        retry_delay: Seconds to wait between retries.

    Returns:
        True if the lock is stale or cannot be verified as valid.
    """
    import time

    for _ in range(max_retries + 1):
        info = _read_lock_info(lock_dir)
        if info is not None:
            break
        # Info file might not be written yet (race condition with lock creator)
        time.sleep(retry_delay)
    else:
        # Info file still missing after retries - consider it stale
        return True

    pid = info.get("pid")
    if pid is not None and not _is_process_alive(pid):
        return True

    timestamp = info.get("timestamp")
    if timestamp is not None and (time.time() - timestamp) > (stale_ms / 1000.0):
        return True

    return False


def _try_acquire_lock_dir(lock_dir: str) -> bool:
    """Attempt to atomically acquire the lock via mkdir.

    Returns True if lock was acquired, False if already exists.
    """
    try:
        os.makedirs(lock_dir, exist_ok=False)
        _write_lock_info(lock_dir)
        return True
    except FileExistsError:
        return False
    except OSError:
        return False


def _release_lock_dir(lock_dir: str) -> None:
    """Release the lock by removing the lock directory."""
    import shutil

    try:
        shutil.rmtree(lock_dir, ignore_errors=True)
    except OSError:
        pass


@asynccontextmanager
async def cross_process_file_lock(
    file_path: str,
    *,
    stale_ms: int = _CROSS_PROCESS_STALE_MS,
    retries: int = _CROSS_PROCESS_RETRIES,
    retry_delay: float = _CROSS_PROCESS_RETRY_DELAY,
):
    """Async context manager for cross-process file locking.

    Uses mkdir-based atomic lock acquisition. Safe across multiple
    CLI instances or concurrent processes operating on the same file.

    Stale lock detection: if the owning process is dead or the lock
    is older than ``stale_ms``, the lock is reclaimed automatically.

    Usage::

        async with cross_process_file_lock("/path/to/config.json"):
            # Only one process at a time for this file
            await write_config(...)

    Args:
        file_path: Path to the file to lock.
        stale_ms: Time in ms after which a lock is considered stale.
        retries: Number of acquisition attempts before raising.
        retry_delay: Seconds between retry attempts.

    Yields:
        None when the lock is acquired.

    Raises:
        TimeoutError: If the lock cannot be acquired after all retries.
    """
    lock_dir = _lock_dir_path(file_path)

    for attempt in range(retries):
        if _try_acquire_lock_dir(lock_dir):
            try:
                yield
            finally:
                _release_lock_dir(lock_dir)
            return

        # Check if existing lock is stale
        if os.path.isdir(lock_dir) and _is_lock_stale(lock_dir, stale_ms):
            _release_lock_dir(lock_dir)
            continue  # Retry immediately after clearing stale lock

        await asyncio.sleep(retry_delay)

    raise TimeoutError(
        f"Failed to acquire cross-process lock for {file_path} after {retries} attempts"
    )


@contextmanager
def cross_process_file_lock_sync(
    file_path: str,
    *,
    stale_ms: int = _CROSS_PROCESS_STALE_MS,
    retries: int = _CROSS_PROCESS_RETRIES,
    retry_delay: float = _CROSS_PROCESS_RETRY_DELAY,
):
    """Sync context manager for cross-process file locking.

    Same semantics as :func:`cross_process_file_lock` but for sync code.

    Usage::

        with cross_process_file_lock_sync("/path/to/config.json"):
            write_config(...)

    Args:
        file_path: Path to the file to lock.
        stale_ms: Time in ms after which a lock is considered stale.
        retries: Number of acquisition attempts before raising.
        retry_delay: Seconds between retry attempts.

    Yields:
        None when the lock is acquired.

    Raises:
        TimeoutError: If the lock cannot be acquired after all retries.
    """
    import time

    lock_dir = _lock_dir_path(file_path)

    for attempt in range(retries):
        if _try_acquire_lock_dir(lock_dir):
            try:
                yield
            finally:
                _release_lock_dir(lock_dir)
            return

        if os.path.isdir(lock_dir) and _is_lock_stale(lock_dir, stale_ms):
            _release_lock_dir(lock_dir)
            continue

        time.sleep(retry_delay)

    raise TimeoutError(
        f"Failed to acquire cross-process lock for {file_path} after {retries} attempts"
    )
