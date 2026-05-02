"""Buffer-pooled file header reading for efficient binary detection.

Ported from oh-my-pi's peek-file.ts pattern.

Provides efficient file header peeking with reusable buffer pools to
avoid allocation churn when detecting binary files, MIME types, or BOMs
across many files (e.g., during ``list_files`` with 1000+ entries).

The sync pool uses a single growable buffer (safe because sync reads
are inherently sequential within a thread). The async pool uses a fixed
set of pre-allocated buffers with a bounded waiter queue.

Usage:
    from code_puppy.utils.peek_file import peek_file_sync, peek_file

    # Sync: check if a file is binary by reading first 512 bytes
    is_binary = peek_file_sync(path, 512, lambda header: b'\\x00' in header)

    # Async: same check in async context
    is_binary = await peek_file(path, 512, lambda header: b'\\x00' in header)
"""

import asyncio
import os
import threading
from collections.abc import Callable

__all__ = [
    "peek_file_sync",
    "peek_file",
    "reset_pools",
]

# --- Pool configuration ---
_POOLED_BUFFER_SIZE = 512  # Async pool slot size; larger peeks allocate ad hoc
_ASYNC_POOL_SIZE = 8  # Number of pre-allocated async buffers
_MAX_ASYNC_WAITERS = 4  # Cap waiter queue to avoid unbounded backlog
_INITIAL_SYNC_BUFFER_SIZE = 1024
_EMPTY = b""

# --- Sync pool ---
# Single growable buffer (thread-local safety not needed because callers
# must hold the GIL during sync reads anyway).
_sync_buf = bytearray(_INITIAL_SYNC_BUFFER_SIZE)
_sync_lock = threading.Lock()

# --- Async pool ---
_async_pool: list[bytearray] = [
    bytearray(_POOLED_BUFFER_SIZE) for _ in range(_ASYNC_POOL_SIZE)
]
_async_available: list[int] = list(range(_ASYNC_POOL_SIZE))
_async_waiters: list[asyncio.Future[int]] = []
_async_lock = asyncio.Lock()


def _acquire_async_index() -> int | asyncio.Future[int]:
    """Try to acquire an async pool slot index.

    Returns an int (slot index) if immediately available, or an
    asyncio.Future that resolves to an int when a slot frees up.
    Returns -1 if the waiter queue is full (caller should allocate ad hoc).
    """
    if _async_available:
        return _async_available.pop()
    if len(_async_waiters) >= _MAX_ASYNC_WAITERS:
        return -1
    loop = asyncio.get_running_loop()
    future: asyncio.Future[int] = loop.create_future()
    _async_waiters.append(future)
    return future


def _release_async_index(index: int) -> None:
    """Release an async pool slot back to the pool."""
    if index < 0:
        return
    if _async_waiters:
        waiter = _async_waiters.pop(0)
        if not waiter.done():
            waiter.set_result(index)
            return
    _async_available.append(index)


def peek_file_sync[T](
    file_path: str | os.PathLike[str],
    max_bytes: int,
    op: Callable[[bytes], T],
) -> T:
    """Synchronously read up to ``max_bytes`` from the start of a file.

    Uses a reusable growable buffer to avoid per-call allocation.

    Args:
        file_path: Path to the file to peek.
        max_bytes: Maximum number of bytes to read from offset 0.
        op: Callback receiving the header bytes (may be shorter than
            ``max_bytes`` if the file is smaller). The return value
            of ``op`` is returned from this function.

    Returns:
        Whatever ``op`` returns.

    Raises:
        OSError: If the file cannot be opened or read.
    """
    if max_bytes <= 0:
        return op(_EMPTY)

    global _sync_buf
    with _sync_lock:
        # Grow the buffer if needed
        if max_bytes > len(_sync_buf):
            _sync_buf = bytearray(max_bytes + (max_bytes >> 1))

        fd = os.open(str(file_path), os.O_RDONLY)
        try:
            n = os.readv(fd, [memoryview(_sync_buf)[:max_bytes]])
            header = bytes(_sync_buf[:n])
        finally:
            os.close(fd)

    return op(header)


async def peek_file[T](
    file_path: str | os.PathLike[str],
    max_bytes: int,
    op: Callable[[bytes], T],
) -> T:
    """Asynchronously read up to ``max_bytes`` from the start of a file.

    Uses a pre-allocated buffer pool to reduce allocation churn under
    concurrent file inspection workloads. Falls back to fresh allocation
    when the pool is exhausted or ``max_bytes`` exceeds pool slot size.

    Args:
        file_path: Path to the file to peek.
        max_bytes: Maximum number of bytes to read from offset 0.
        op: Callback receiving the header bytes.

    Returns:
        Whatever ``op`` returns.

    Raises:
        OSError: If the file cannot be opened or read.
    """
    if max_bytes <= 0:
        return op(_EMPTY)

    # For larger reads, always allocate ad hoc
    if max_bytes > _POOLED_BUFFER_SIZE:
        header = await asyncio.to_thread(_sync_read, file_path, max_bytes)
        return op(header)

    # Try to get a pool slot
    async with _async_lock:
        slot = _acquire_async_index()

    pool_index: int
    if isinstance(slot, int):
        pool_index = slot
    else:
        pool_index = await slot

    if pool_index >= 0:
        buf = _async_pool[pool_index]
        try:
            header = await asyncio.to_thread(_sync_read_into, file_path, buf, max_bytes)
            return op(header)
        finally:
            async with _async_lock:
                _release_async_index(pool_index)
    else:
        # Pool and waiter queue full — allocate ad hoc
        header = await asyncio.to_thread(_sync_read, file_path, max_bytes)
        return op(header)


def _sync_read(file_path: str | os.PathLike[str], max_bytes: int) -> bytes:
    """Read up to max_bytes from file start (fresh allocation)."""
    fd = os.open(str(file_path), os.O_RDONLY)
    try:
        return os.read(fd, max_bytes)
    finally:
        os.close(fd)


def _sync_read_into(
    file_path: str | os.PathLike[str],
    buf: bytearray,
    max_bytes: int,
) -> bytes:
    """Read up to max_bytes from file start into pre-allocated buffer."""
    fd = os.open(str(file_path), os.O_RDONLY)
    try:
        n = os.readv(fd, [memoryview(buf)[:max_bytes]])
        return bytes(buf[:n])
    finally:
        os.close(fd)


def reset_pools() -> None:
    """Reset both buffer pools to initial state.

    Intended for testing. Not thread-safe with concurrent peek operations.
    """
    global _sync_buf
    _sync_buf = bytearray(_INITIAL_SYNC_BUFFER_SIZE)
    _async_available.clear()
    _async_available.extend(range(_ASYNC_POOL_SIZE))
    _async_waiters.clear()
    for i in range(_ASYNC_POOL_SIZE):
        _async_pool[i] = bytearray(_POOLED_BUFFER_SIZE)
