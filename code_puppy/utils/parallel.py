"""
Parallel worker pool utilities for Code Puppy.

Provides a bounded-concurrency async map and a from-scratch counting semaphore.

Inspired by oh-my-pi's parallel.ts.
"""

import asyncio
import collections
from collections.abc import Callable
from dataclasses import dataclass
from typing import Awaitable, TypeVar

T = TypeVar("T")
R = TypeVar("R")


@dataclass
class ParallelResult[R]:
    """Result of a parallel map operation.

    Attributes:
        results: Ordered results matching the input list.  Entries for tasks
            that were skipped due to an abort signal are ``None``.
        aborted: ``True`` when the operation was cut short by the abort signal.
    """

    results: list[R | None]
    aborted: bool = False


class Semaphore:
    """Async counting semaphore for controlling concurrency.

    Written from scratch using an explicit ``asyncio.Future`` queue rather than
    delegating to ``asyncio.Semaphore``.  This mirrors the low-level slot/waiter
    pattern used in oh-my-pi's parallel.ts.

    Usage::

        sem = Semaphore(3)

        async with sem:
            await do_work()

        # or manually:
        await sem.acquire()
        try:
            await do_work()
        finally:
            sem.release()
    """

    def __init__(self, max_concurrent: int) -> None:
        if max_concurrent < 1:
            raise ValueError(f"max_concurrent must be >= 1, got {max_concurrent}")
        self._max = max_concurrent
        # Available slots (0 means fully occupied).
        self._available: int = max_concurrent
        # Queue of futures waiting for a slot; each future resolves to None
        # when a slot is granted.
        self._waiters: collections.deque[asyncio.Future[None]] = collections.deque()

    async def acquire(self) -> None:
        """Wait until a concurrency slot is available, then occupy it."""
        if self._available > 0:
            self._available -= 1
            return
        # No slots free — park a Future on the waiter queue.
        loop = asyncio.get_running_loop()
        future: asyncio.Future[None] = loop.create_future()
        self._waiters.append(future)
        await future  # blocks until release() resolves us

    def release(self) -> None:
        """Free the held slot, granting it directly to the next waiter if any.

        Raises:
            RuntimeError: If called more times than :meth:`acquire` (double-release).
        """
        if self._waiters:
            # Hand the slot directly to the oldest waiter — don't increment
            # _available since the slot stays occupied by the new holder.
            future = self._waiters.popleft()
            if not future.done():
                future.set_result(None)
        else:
            if self._available >= self._max:
                raise RuntimeError(
                    f"Semaphore.release() called too many times "
                    f"(available={self._available}, max={self._max})"
                )
            self._available += 1

    async def __aenter__(self) -> "Semaphore":
        await self.acquire()
        return self

    async def __aexit__(self, *_: object) -> None:
        self.release()


async def map_with_concurrency(
    items: list[T],
    concurrency: int,
    fn: Callable[[T, int], Awaitable[R]],
    signal: asyncio.Event | None = None,
) -> ParallelResult[R]:
    """Apply *fn* to every item in *items* with at most *concurrency* tasks running
    simultaneously.

    The worker-pool pattern mirrors oh-my-pi's parallel.ts: a fixed number of
    worker coroutines race to claim the next unprocessed index, keeping the
    concurrency cap constant without spawning one task per item.

    Args:
        items:       Items to process.
        concurrency: Maximum simultaneous operations.  Clamped to ``[1, len(items)]``.
        fn:          Async function called as ``fn(item, index) -> R``.
        signal:      Optional :class:`asyncio.Event`.  When set, workers stop
                     picking up new items and the result is marked as aborted.
                     Tasks that are already running are allowed to complete.

    Returns:
        :class:`ParallelResult` whose ``results`` list preserves input ordering.
        Skipped entries (due to abort) are ``None``.

    Raises:
        Any exception raised by *fn* — the remaining workers are cancelled and
        the first error is re-raised immediately (fail-fast semantics).
    """
    if not items:
        return ParallelResult(results=[], aborted=False)

    n = len(items)
    # Clamp concurrency to a sensible range.
    concurrency = max(1, min(concurrency, n))

    results: list[R | None] = [None] * n
    _next_index: int = 0
    _index_lock = asyncio.Lock()
    _was_aborted: bool = False

    async def _worker() -> None:
        nonlocal _next_index, _was_aborted

        while True:
            # Claim the next index under the lock.
            async with _index_lock:
                if _next_index >= n:
                    # No more work.
                    return
                if signal is not None and signal.is_set():
                    _was_aborted = True
                    return
                idx = _next_index
                _next_index += 1

            # Process the item outside the lock so other workers can proceed.
            results[idx] = await fn(items[idx], idx)

    # Spawn exactly `concurrency` worker tasks.
    tasks = [asyncio.create_task(_worker()) for _ in range(concurrency)]

    try:
        # gather with default return_exceptions=False: the first exception
        # raised by a worker is re-raised here immediately.
        await asyncio.gather(*tasks)
    except Exception:
        # Fail-fast: cancel every still-running worker, then re-raise.
        for task in tasks:
            if not task.done():
                task.cancel()
        # Await cancellation (swallow CancelledError / other exceptions from
        # already-failed tasks so they don't interfere).
        await asyncio.gather(*tasks, return_exceptions=True)
        raise

    return ParallelResult(results=results, aborted=_was_aborted)


@dataclass
class BulkheadStats:
    """Snapshot of bulkhead throughput counters.

    Attributes:
        active: Currently executing tasks.
        queued: Tasks waiting in the overflow queue.
        max_concurrent: Configured concurrency limit.
        max_queue: Configured queue capacity.
        completed: Total successful executions since last reset.
        rejected: Total rejections (queue full) since last reset.
        timed_out: Total queue-timeout expirations since last reset.
    """

    active: int
    queued: int
    max_concurrent: int
    max_queue: int
    completed: int
    rejected: int
    timed_out: int


class BulkheadFullError(Exception):
    """Raised when the bulkhead's concurrent slots AND overflow queue are both full."""

    def __init__(self, name: str, max_concurrent: int, max_queue: int) -> None:
        self.bulkhead_name = name
        self.max_concurrent = max_concurrent
        self.max_queue = max_queue
        super().__init__(
            f"Bulkhead '{name}' is full "
            f"(max_concurrent={max_concurrent}, max_queue={max_queue})"
        )


class BulkheadTimeoutError(Exception):
    """Raised when a queued item exceeds its queue timeout."""

    def __init__(self, name: str, queue_timeout: float) -> None:
        self.bulkhead_name = name
        self.queue_timeout = queue_timeout
        super().__init__(f"Bulkhead '{name}' queue timeout after {queue_timeout}s")


class Bulkhead:
    """Bounded-concurrency execution gate with overflow queue.

    Limits concurrent task execution to ``max_concurrent``.  When all slots
    are occupied, new tasks are queued (up to ``max_queue``).  Queued tasks
    are given a ``queue_timeout`` — if a slot doesn't open in time, a
    :class:`BulkheadTimeoutError` is raised.

    This is complementary to :func:`map_with_concurrency` (which is
    batch-oriented).  The Bulkhead is designed for **service-style
    throttling** where tasks arrive continuously.

    Inspired by ruflo's ``resilience/bulkhead.ts`` — ported to async Python
    with ``asyncio`` primitives.

    Usage::

        bulkhead = Bulkhead("llm-api", max_concurrent=5, max_queue=20)

        result = await bulkhead.execute(lambda: call_api(prompt))

    Args:
        name: Identifier for logging and error messages.
        max_concurrent: Maximum simultaneous executions (default 10).
        max_queue: Maximum overflow queue depth (default 100).
        queue_timeout: Seconds before a queued item times out (default 30.0).
    """

    def __init__(
        self,
        name: str,
        max_concurrent: int = 10,
        max_queue: int = 100,
        queue_timeout: float = 30.0,
    ) -> None:
        if max_concurrent < 1:
            raise ValueError(f"max_concurrent must be >= 1, got {max_concurrent}")
        if max_queue < 0:
            raise ValueError(f"max_queue must be >= 0, got {max_queue}")

        self.name = name
        self._max_concurrent = max_concurrent
        self._max_queue = max_queue
        self._queue_timeout = queue_timeout

        self._active = 0
        self._gate = asyncio.Semaphore(max_concurrent)
        self._queue_depth = 0
        self._lock = asyncio.Lock()

        # Stats
        self._completed = 0
        self._rejected = 0
        self._timed_out = 0

    async def execute(self, fn: Callable[[], Awaitable[R]]) -> R:
        """Execute *fn* within the bulkhead's concurrency limits.

        If a slot is immediately available, *fn* runs right away.
        Otherwise it is queued.  Raises :class:`BulkheadFullError` if
        the queue is also full, or :class:`BulkheadTimeoutError` if the
        queue wait exceeds ``queue_timeout``.

        Args:
            fn: Async callable to execute.

        Returns:
            The return value of *fn*.
        """
        # Fast path: try to acquire without blocking
        acquired = self._gate._value > 0  # noqa: SLF001 — peek only
        if not acquired:
            # Check queue capacity
            async with self._lock:
                if self._queue_depth >= self._max_queue:
                    self._rejected += 1
                    raise BulkheadFullError(
                        self.name, self._max_concurrent, self._max_queue
                    )
                self._queue_depth += 1

            # Wait for a slot with timeout
            try:
                await asyncio.wait_for(
                    self._gate.acquire(), timeout=self._queue_timeout
                )
            except asyncio.TimeoutError:
                async with self._lock:
                    self._queue_depth -= 1
                    self._timed_out += 1
                raise BulkheadTimeoutError(self.name, self._queue_timeout) from None
            else:
                async with self._lock:
                    self._queue_depth -= 1
        else:
            await self._gate.acquire()

        # We have a slot — execute
        async with self._lock:
            self._active += 1
        try:
            return await fn()
        finally:
            async with self._lock:
                self._active -= 1
                self._completed += 1
            self._gate.release()

    def has_capacity(self) -> bool:
        """Return ``True`` if there is room for at least one more task
        (either a concurrent slot or a queue slot)."""
        return (
            self._gate._value > 0  # noqa: SLF001
            or self._queue_depth < self._max_queue
        )

    def available_capacity(self) -> int:
        """Return total available capacity (free slots + free queue space)."""
        free_slots = self._gate._value  # noqa: SLF001
        free_queue = self._max_queue - self._queue_depth
        return free_slots + free_queue

    def get_stats(self) -> BulkheadStats:
        """Return a snapshot of current bulkhead statistics."""
        return BulkheadStats(
            active=self._active,
            queued=self._queue_depth,
            max_concurrent=self._max_concurrent,
            max_queue=self._max_queue,
            completed=self._completed,
            rejected=self._rejected,
            timed_out=self._timed_out,
        )

    def reset_stats(self) -> None:
        """Reset throughput counters (completed, rejected, timed_out) to zero."""
        self._completed = 0
        self._rejected = 0
        self._timed_out = 0
