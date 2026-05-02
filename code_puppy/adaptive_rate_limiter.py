"""Adaptive rate limiter that dynamically adjusts concurrency per model.

When an HTTP 429 (Too Many Requests) is detected for a specific model,
the concurrency limit for that model is reduced. A background recovery
task gradually restores the limit once the cooldown period has elapsed.

**Circuit Breaker Integration:**

On 429, a circuit breaker enters the **OPEN** state, queuing all new
requests instead of sending them. After a cooldown period it enters
**HALF_OPEN** and allows one test request. If the test succeeds the
circuit **CLOSES** and queued requests are gradually released; if the
test triggers another 429 the cooldown is doubled and the circuit
stays OPEN.

The module is a **singleton** – all state lives in a ``_RateLimiterState``
instance, matching the pattern used by ``concurrency_limits.py``.
"""

import asyncio
import functools
import logging
import math
import time
from dataclasses import dataclass, field
from typing import Any

from code_puppy.circuit_state import CircuitState

logger = logging.getLogger(__name__)


# ── Tunable defaults ────────────────────────────────────────────────────────

DEFAULT_MIN_LIMIT: int = 1
DEFAULT_MAX_LIMIT: int = 10
DEFAULT_COOLDOWN_SECONDS: float = 60.0
DEFAULT_RECOVERY_RATE: float = 0.5  # fraction of current limit to add per tick
DEFAULT_INITIAL_LIMIT: int = 10  # starting concurrency for any new model
LIMIT_EPSILON: float = 0.01  # epsilon for float comparison of limits

# Circuit breaker defaults
DEFAULT_CIRCUIT_BREAKER_ENABLED: bool = False
DEFAULT_CIRCUIT_COOLDOWN_SECONDS: float = 10.0
DEFAULT_CIRCUIT_HALF_OPEN_REQUESTS: int = 1
DEFAULT_QUEUE_MAX_SIZE: int = 100
DEFAULT_RELEASE_RATE: float = 1.0  # requests per second


# ── Per-model state ─────────────────────────────────────────────────────────


@dataclass(slots=True)
class ModelRateLimitState:
    """Tracks rate-limit health for a single model.

    Uses an ``asyncio.Condition`` + counter instead of ``Semaphore``
    because Python 3.14 removed ``Semaphore.acquire_nowait()`` and
    ``Semaphore.locked()``, making it impossible to shrink a semaphore
    without risking deadlock. The condition-based approach lets us
    dynamically lower ``current_limit`` and have waiters observe the
    change immediately.
    """

    current_limit: float
    active_count: int = 0
    last_429_time: float | None = None
    total_429_count: int = 0
    last_used_time: float = field(default_factory=time.monotonic)
    condition: asyncio.Condition = field(default=None, repr=False)

    # Circuit breaker fields
    circuit_state: CircuitState = CircuitState.CLOSED
    circuit_opened_time: float = 0.0
    cooldown_multiplier: float = 1.0
    half_open_test_count: int = 0
    # Lazy allocation: queue is None until circuit actually opens
    request_queue: asyncio.Queue | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if self.condition is None:
            self.condition = asyncio.Condition()
        # Note: request_queue is lazily allocated by _ensure_queue()


# ── Singleton state ─────────────────────────────────────────────────────────


class _RateLimiterState:
    """Encapsulates all module-level mutable state for the rate limiter.

    A single ``_state`` instance is created at module load time. All
    internal functions read from and write to this object, eliminating
    the need for ``global`` declarations.
    """

    __slots__ = (
        "model_states",
        "lock",
        "recovery_task",
        "recovery_started",
        "circuit_tasks",
        "cfg_min_limit",
        "cfg_max_limit",
        "cfg_cooldown_seconds",
        "cfg_recovery_rate",
        "cfg_initial_limit",
        "cfg_circuit_breaker_enabled",
        "cfg_circuit_cooldown_seconds",
        "cfg_circuit_half_open_requests",
        "cfg_queue_max_size",
        "cfg_release_rate",
    )

    def __init__(self) -> None:
        # Runtime state
        self.model_states: dict[str, ModelRateLimitState] = {}
        self.lock: asyncio.Lock | None = None
        self.recovery_task: asyncio.Task | None = None
        self.recovery_started: bool = False
        self.circuit_tasks: set[asyncio.Task] = set()

        # Configurable knobs – may be overridden before first use via configure()
        self.cfg_min_limit: int = DEFAULT_MIN_LIMIT
        self.cfg_max_limit: int = DEFAULT_MAX_LIMIT
        self.cfg_cooldown_seconds: float = DEFAULT_COOLDOWN_SECONDS
        self.cfg_recovery_rate: float = DEFAULT_RECOVERY_RATE
        self.cfg_initial_limit: int = DEFAULT_INITIAL_LIMIT

        # Circuit breaker config knobs
        self.cfg_circuit_breaker_enabled: bool = DEFAULT_CIRCUIT_BREAKER_ENABLED
        self.cfg_circuit_cooldown_seconds: float = DEFAULT_CIRCUIT_COOLDOWN_SECONDS
        self.cfg_circuit_half_open_requests: int = DEFAULT_CIRCUIT_HALF_OPEN_REQUESTS
        self.cfg_queue_max_size: int = DEFAULT_QUEUE_MAX_SIZE
        self.cfg_release_rate: float = DEFAULT_RELEASE_RATE

    def reset_to_defaults(self) -> None:
        """Restore every knob to its compile-time default.

        Called by the public :func:`reset` function.
        """
        self.cfg_min_limit = DEFAULT_MIN_LIMIT
        self.cfg_max_limit = DEFAULT_MAX_LIMIT
        self.cfg_cooldown_seconds = DEFAULT_COOLDOWN_SECONDS
        self.cfg_recovery_rate = DEFAULT_RECOVERY_RATE
        self.cfg_initial_limit = DEFAULT_INITIAL_LIMIT
        self.cfg_circuit_breaker_enabled = DEFAULT_CIRCUIT_BREAKER_ENABLED
        self.cfg_circuit_cooldown_seconds = DEFAULT_CIRCUIT_COOLDOWN_SECONDS
        self.cfg_circuit_half_open_requests = DEFAULT_CIRCUIT_HALF_OPEN_REQUESTS
        self.cfg_queue_max_size = DEFAULT_QUEUE_MAX_SIZE
        self.cfg_release_rate = DEFAULT_RELEASE_RATE


_state = _RateLimiterState()


# ── Internal helpers ────────────────────────────────────────────────────────


def _ensure_lock() -> asyncio.Lock:
    """Return the module-level asyncio.Lock, creating it if needed."""
    if _state.lock is None:
        _state.lock = asyncio.Lock()
    return _state.lock


@functools.lru_cache(maxsize=128)
def _normalize_model_name(model_name: str) -> str | None:
    """Normalize model name to lowercase and strip whitespace.

    Returns None if the model name is empty after normalization.
    """
    if not model_name:
        return None
    key = model_name.lower().strip()
    return key if key else None


def _ensure_state(model_name: str) -> ModelRateLimitState:
    """Get or create state for *model_name* (caller must hold ``_state.lock``)."""
    if model_name not in _state.model_states:
        _state.model_states[model_name] = ModelRateLimitState(
            current_limit=float(_state.cfg_initial_limit),
        )
        logger.debug(
            "adaptive_rate_limiter: initialised model %r with limit %.0f",
            model_name,
            _state.cfg_initial_limit,
        )
    return _state.model_states[model_name]


def _ensure_queue(state: ModelRateLimitState) -> asyncio.Queue:
    """Lazily allocate the request queue for circuit breaker use.

    Queue is only created when the circuit actually opens, saving memory
    for the common case where circuit breaker is disabled or never triggers.
    """
    if state.request_queue is None:
        state.request_queue = asyncio.Queue(maxsize=_state.cfg_queue_max_size)
    return state.request_queue


def _cleanup_old_states(max_age_seconds: float = 3600) -> int:
    """Remove stale model states that have been idle for too long.

    Only removes states where:
    - active_count == 0 (no in-flight requests)
    - request_queue is empty or None
    - last_used_time is older than max_age_seconds

    This function creates a snapshot of keys to avoid RuntimeError from
    dict mutation during iteration under high concurrency.
    """
    now = time.monotonic()

    # First pass: identify stale keys (snapshot to avoid mutation issues)
    # We iterate over list() to protect against concurrent modifications
    stale_keys = [
        key
        for key, state in list(_state.model_states.items())
        if state.active_count == 0
        and (state.request_queue is None or state.request_queue.empty())
        and (now - state.last_used_time) > max_age_seconds
    ]

    # Second pass: delete identified keys using pop (safe even if key removed)
    for key in stale_keys:
        _state.model_states.pop(key, None)

    if stale_keys:
        logger.debug(
            "adaptive_rate_limiter: cleaned up %d stale model state(s)",
            len(stale_keys),
        )
    return len(stale_keys)


async def _recovery_loop() -> None:
    """Background coroutine that gradually restores rate limits.

    Runs once per ``_state.cfg_cooldown_seconds``. For every model that has
    been throttled, it increases the limit by ``_state.cfg_recovery_rate`` of
    the current value (or +1, whichever is larger), capped at
    ``_state.cfg_max_limit``.

    Also periodically prunes stale model states to prevent unbounded
    memory growth.
    """
    logger.info("adaptive_rate_limiter: recovery loop started")
    try:
        while True:
            await asyncio.sleep(_state.cfg_cooldown_seconds)
            lock = _ensure_lock()

            # Snapshot state under lock, then process outside the lock
            recovery_items = []
            cleanup_needed = False

            async with lock:
                # Periodically clean up stale model states
                if len(_state.model_states) > 100:
                    cleanup_needed = True

                now = time.monotonic()
                for model_name, st in _state.model_states.items():
                    if st.last_429_time is None:
                        continue
                    elapsed = now - st.last_429_time
                    if elapsed < _state.cfg_cooldown_seconds:
                        continue  # still in cooldown

                    old_limit = st.current_limit
                    increment = max(1.0, st.current_limit * _state.cfg_recovery_rate)
                    new_limit = min(
                        st.current_limit + increment,
                        float(_state.cfg_max_limit),
                    )
                    if abs(new_limit - old_limit) < LIMIT_EPSILON:
                        continue  # already at max

                    # Capture recovery item to process outside the lock
                    recovery_items.append(
                        (model_name, st, old_limit, new_limit, elapsed)
                    )

            # Perform cleanup outside the lock if needed
            if cleanup_needed:
                removed = _cleanup_old_states(max_age_seconds=3600)
                if removed:
                    logger.info(
                        "adaptive_rate_limiter: pruned %d stale state(s), %d remaining",
                        removed,
                        len(_state.model_states),
                    )

            # Process recovery mutations outside the lock
            for model_name, st, old_limit, new_limit, elapsed in recovery_items:
                st.current_limit = new_limit
                # Wake any waiters that may now be unblocked
                async with st.condition:
                    st.condition.notify_all()
                logger.info(
                    "adaptive_rate_limiter: %r limit recovered %.1f → %.0f "
                    "(after %.0fs cooldown)",
                    model_name,
                    old_limit,
                    new_limit,
                    elapsed,
                )
    except asyncio.CancelledError:
        logger.info("adaptive_rate_limiter: recovery loop cancelled")
    except Exception:
        logger.exception("adaptive_rate_limiter: recovery loop error")


def _ensure_recovery_task() -> None:
    """Start the background recovery task if it isn't running yet.

    Safe to call from sync code; the task is scheduled on the running
    event loop.
    """
    if _state.recovery_started:
        return
    _state.recovery_started = True
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if loop is not None and loop.is_running():
        _state.recovery_task = loop.create_task(_recovery_loop())
    else:
        # No running loop yet – will be started on next async call.
        _state.recovery_started = False


# ── Circuit breaker internals ───────────────────────────────────────────────


async def _circuit_cooldown_loop(model_name: str, state: ModelRateLimitState) -> None:
    """Background task: wait for cooldown then transition to HALF_OPEN.

    Runs per-model when the circuit opens. After the cooldown period
    elapses, the circuit transitions to HALF_OPEN which allows test
    requests through.
    """
    effective_cooldown = _state.cfg_circuit_cooldown_seconds * state.cooldown_multiplier
    logger.info(
        "Circuit OPEN for %r: holding requests for %.1fs (cooldown ×%.0f)",
        model_name,
        effective_cooldown,
        state.cooldown_multiplier,
    )
    try:
        await asyncio.sleep(effective_cooldown)
        lock = _ensure_lock()
        async with lock:
            # Only transition if still OPEN (might have been force-closed)
            if state.circuit_state == CircuitState.OPEN:
                state.circuit_state = CircuitState.HALF_OPEN
                state.half_open_test_count = 0
                logger.info(
                    "Circuit HALF_OPEN for %r: testing with %d request(s)",
                    model_name,
                    _state.cfg_circuit_half_open_requests,
                )
                # Wake any waiters that might want to test the circuit
                async with state.condition:
                    state.condition.notify_all()
    except asyncio.CancelledError:
        pass
    except Exception:
        logger.exception(
            "adaptive_rate_limiter: circuit cooldown loop error for %r",
            model_name,
        )


async def _process_queue(model_name: str, state: ModelRateLimitState) -> None:
    """Background task: gradually release queued requests.

    Called when the circuit transitions from HALF_OPEN → CLOSED.
    Releases one request per second (configurable via ``_state.cfg_release_rate``).
    """
    queue = state.request_queue
    if queue is None:
        return
    total = queue.qsize()
    logger.info(
        "Releasing queued requests (%d pending) for %r at %.1f/s",
        total,
        model_name,
        _state.cfg_release_rate,
    )
    interval = (1.0 / _state.cfg_release_rate) if _state.cfg_release_rate > 0 else 0
    try:
        if total > 0:
            # Batch-notify all waiters so they wake immediately,
            # then rate-limit the actual processing pace.
            async with state.condition:
                for _ in range(total):
                    state.condition.notify_one()
            for i in range(total):
                if interval > 0:
                    await asyncio.sleep(interval)
                logger.info(
                    "Released queued request %d/%d for %r",
                    i + 1,
                    total,
                    model_name,
                )
    except asyncio.CancelledError:
        pass
    except Exception:
        logger.exception(
            "adaptive_rate_limiter: queue processing error for %r",
            model_name,
        )


async def _notify_waiters(state: ModelRateLimitState) -> None:
    """Wake up waiters that may now be able to acquire a slot."""
    async with state.condition:
        state.condition.notify_all()


# ── Circuit breaker public API ──────────────────────────────────────────────


async def open_circuit(model_name: str) -> None:
    """Transition the circuit breaker for *model_name* to OPEN.

    Queues all new ``acquire_model_slot`` calls until the cooldown
    elapses and the circuit enters HALF_OPEN.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    _ensure_recovery_task()
    lock = _ensure_lock()
    async with lock:
        state = _ensure_state(key)
        if state.circuit_state == CircuitState.OPEN:
            # Already open – just increase the cooldown multiplier
            state.cooldown_multiplier = min(state.cooldown_multiplier * 2.0, 64.0)
            logger.warning(
                "Circuit already OPEN for %r, extending cooldown (×%.0f)",
                key,
                state.cooldown_multiplier,
            )
            return

        # 429 during HALF_OPEN → extend cooldown
        if state.circuit_state == CircuitState.HALF_OPEN:
            state.cooldown_multiplier = min(state.cooldown_multiplier * 2.0, 64.0)
            logger.warning(
                "429 during HALF_OPEN for %r, extending cooldown (×%.0f)",
                key,
                state.cooldown_multiplier,
            )
        else:
            state.cooldown_multiplier = 1.0

        state.circuit_state = CircuitState.OPEN
        state.circuit_opened_time = time.monotonic()
        state.half_open_test_count = 0

    # Start the cooldown loop outside the lock
    try:
        loop = asyncio.get_running_loop()
        task = loop.create_task(_circuit_cooldown_loop(key, state))
        _state.circuit_tasks.add(task)
        task.add_done_callback(_state.circuit_tasks.discard)
    except RuntimeError:
        pass


async def close_circuit(model_name: str) -> None:
    """Transition the circuit breaker for *model_name* to CLOSED.

    Resets cooldown multiplier and starts releasing queued requests.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    lock = _ensure_lock()
    state: ModelRateLimitState | None = None
    was_open: bool = False

    async with lock:
        state = _state.model_states.get(key)
        if state is None or state.circuit_state == CircuitState.CLOSED:
            return

        was_open = (
            state.circuit_state == CircuitState.HALF_OPEN
            or state.circuit_state == CircuitState.OPEN
        )
        state.circuit_state = CircuitState.CLOSED
        state.circuit_opened_time = 0.0
        state.cooldown_multiplier = 1.0
        state.half_open_test_count = 0
        logger.info("Circuit CLOSED for %r", key)

        # Wake any waiters that were blocked in acquire_model_slot
        async with state.condition:
            state.condition.notify_all()

    # Start queue processing outside the lock
    if was_open and state is not None:
        try:
            loop = asyncio.get_running_loop()
            task = loop.create_task(_process_queue(key, state))
            _state.circuit_tasks.add(task)
            task.add_done_callback(_state.circuit_tasks.discard)
        except RuntimeError:
            pass


async def record_success(model_name: str) -> None:
    """Signal that a successful (non-429) request completed for *model_name*.

    If the circuit is in HALF_OPEN state and the test request succeeded,
    this transitions the circuit to CLOSED and begins releasing queued
    requests.

    In CLOSED state this is a no-op.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_rate_limiter,
            is_connected,
        )

        if is_connected():
            import asyncio

            try:
                asyncio.create_task(
                    call_elixir_rate_limiter(
                        "rate_limiter.record_success",
                        {"model_name": model_name},
                        timeout=1.0,
                    )
                )
            except Exception:
                pass  # Ignore errors for fire-and-forget
    except ImportError:
        pass

    lock = _ensure_lock()
    should_close = False
    async with lock:
        state = _state.model_states.get(key)
        if state is not None and state.circuit_state == CircuitState.HALF_OPEN:
            should_close = True

    if should_close:
        await close_circuit(key)


# ── Public API ──────────────────────────────────────────────────────────────


def configure(
    *,
    min_limit: int | None = None,
    max_limit: int | None = None,
    cooldown_seconds: float | None = None,
    recovery_rate: float | None = None,
    initial_limit: int | None = None,
    # Circuit breaker config
    circuit_breaker_enabled: bool | None = None,
    circuit_cooldown_seconds: float | None = None,
    circuit_half_open_requests: int | None = None,
    queue_max_size: int | None = None,
    release_rate: float | None = None,
) -> None:
    """Override default configuration knobs.

    Must be called *before* any model state is created (i.e. before the
    first ``record_rate_limit`` / ``acquire_model_slot`` call).
    """
    if min_limit is not None:
        _state.cfg_min_limit = max(1, min_limit)
    if max_limit is not None:
        _state.cfg_max_limit = max(_state.cfg_min_limit, max_limit)
    if cooldown_seconds is not None:
        _state.cfg_cooldown_seconds = max(1.0, cooldown_seconds)
    if recovery_rate is not None:
        _state.cfg_recovery_rate = max(0.0, min(1.0, recovery_rate))
    if initial_limit is not None:
        _state.cfg_initial_limit = max(
            _state.cfg_min_limit, min(initial_limit, _state.cfg_max_limit)
        )

    if circuit_breaker_enabled is not None:
        _state.cfg_circuit_breaker_enabled = circuit_breaker_enabled
    if circuit_cooldown_seconds is not None:
        _state.cfg_circuit_cooldown_seconds = max(0.1, circuit_cooldown_seconds)
    if circuit_half_open_requests is not None:
        _state.cfg_circuit_half_open_requests = max(1, circuit_half_open_requests)
    if queue_max_size is not None:
        _state.cfg_queue_max_size = max(1, queue_max_size)
    if release_rate is not None:
        _state.cfg_release_rate = max(0.0, release_rate)


async def record_rate_limit(model_name: str) -> None:
    """Signal that *model_name* just received an HTTP 429 response.

    The concurrency limit for this model is immediately reduced by 50 %
    (but never below ``min_limit``). The circuit breaker also opens,
    queuing all new requests until the cooldown elapses.

    Bridge-aware - notifies Elixir bridge if connected (fire-and-forget).
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    # Notify Elixir bridge if connected (fire-and-forget)
    try:
        from code_puppy.plugins.elixir_bridge import (
            call_elixir_rate_limiter,
            is_connected,
        )

        if is_connected():
            import asyncio

            try:
                asyncio.create_task(
                    call_elixir_rate_limiter(
                        "rate_limiter.record_limit",
                        {"model_name": model_name},
                        timeout=1.0,
                    )
                )
            except Exception:
                pass  # Ignore errors for fire-and-forget
    except ImportError:
        pass

    _ensure_recovery_task()
    lock = _ensure_lock()
    async with lock:
        state = _ensure_state(key)
        state.last_429_time = time.monotonic()
        state.total_429_count += 1
        old_limit = state.current_limit
        new_limit = max(float(_state.cfg_min_limit), state.current_limit * 0.5)
        state.current_limit = new_limit
        logger.warning(
            "adaptive_rate_limiter: %r rate-limited (429 #%d), "
            "limit reduced %.1f → %.1f",
            key,
            state.total_429_count,
            old_limit,
            new_limit,
        )

    # Open the circuit breaker if enabled (outside the lock)
    if _state.cfg_circuit_breaker_enabled:
        await open_circuit(key)


async def acquire_model_slot(
    model_name: str,
    timeout: float | None = 300.0,
) -> None:
    """Acquire an adaptive concurrency slot for *model_name*.

    Lock Usage (Sequential, Not Nested):

    This function uses two locks acquired in sequence, never simultaneously:

    1. _state.lock — acquired first to safely look up/create the per-model
       state entry in the global _state.model_states dict, then released.
    2. state.condition — acquired second to wait for and claim a concurrency
       slot for this specific model.

    Because the locks are never held simultaneously, deadlock from lock
    ordering is not possible. condition.wait() releases only the condition's
    internal lock (the only lock held at that point).

    Blocks until a slot is available. The first call for any model
    auto-starts the background recovery task.

    **Circuit breaker behaviour:**

    * **CLOSED** – normal slot acquisition.
    * **OPEN** – the call blocks and is queued until the cooldown
      elapses (circuit → HALF_OPEN → test request → CLOSED).
    * **HALF_OPEN** – the call is allowed only if the test-request
      budget has not been exhausted.

    Args:
        model_name: The model to acquire a slot for.
        timeout: Maximum seconds to wait for a slot. Pass ``None`` to
            wait indefinitely (not recommended). Defaults to 300 s.

    Raises:
        asyncio.TimeoutError: If a slot cannot be acquired within
            *timeout* seconds.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    _ensure_recovery_task()
    lock = _ensure_lock()
    cb_enabled = _state.cfg_circuit_breaker_enabled

    # ── Check circuit state (only when circuit breaker enabled) ──────
    if cb_enabled:
        need_wait_open = False
        need_wait_half_open = False

        async with lock:
            state = _ensure_state(key)

            if state.circuit_state == CircuitState.OPEN:
                queue = state.request_queue
                if queue is not None and queue.full():
                    logger.warning(
                        "Circuit queue full for %r – request will still wait",
                        key,
                    )
                need_wait_open = True

            elif state.circuit_state == CircuitState.HALF_OPEN:
                if state.half_open_test_count >= _state.cfg_circuit_half_open_requests:
                    need_wait_half_open = True
                else:
                    state.half_open_test_count += 1
                    logger.info(
                        "Circuit HALF_OPEN test request %d/%d for %r",
                        state.half_open_test_count,
                        _state.cfg_circuit_half_open_requests,
                        key,
                    )

        # Wait using the condition lock — this avoids the TOCTOU race
        # that occurred when state was checked under _lock but waited
        # under a different lock (state.condition). The condition lock
        # serialises both the check and the wait so no state change can
        # be missed.
        if need_wait_open:
            async with state.condition:
                # Re-check under condition lock to close the TOCTOU gap
                while state.circuit_state == CircuitState.OPEN:
                    await asyncio.wait_for(
                        state.condition.wait(),
                        timeout=timeout,
                    )

        elif need_wait_half_open:
            async with state.condition:
                while state.circuit_state == CircuitState.HALF_OPEN:
                    await asyncio.wait_for(
                        state.condition.wait(),
                        timeout=timeout,
                    )

    # ── Normal slot acquisition ─────────────────────────────────────────
    async with lock:
        state = _state.model_states.get(key)
        if state is None:
            state = _ensure_state(key)

    async with state.condition:
        while state.active_count >= math.ceil(state.current_limit):
            await asyncio.wait_for(
                state.condition.wait(),
                timeout=timeout,
            )
        state.active_count += 1
        state.last_used_time = time.monotonic()


async def release_model_slot_async(model_name: str) -> None:
    """Release an adaptive concurrency slot (async version - preferred).

    This version correctly performs the release under the condition lock,
    preventing race conditions with waiters.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    state = _state.model_states.get(key)
    if state is not None:
        async with state.condition:
            state.active_count = max(0, state.active_count - 1)
            state.last_used_time = time.monotonic()  # Track for cleanup
            state.condition.notify_all()


def release_model_slot(model_name: str) -> None:
    """Release an adaptive concurrency slot for *model_name*.

    This is synchronous but schedules the actual release on the event loop
    to ensure proper locking. Prefer `release_model_slot_async` in async code.

    Must be called exactly once for every successful `acquire_model_slot` call.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return

    try:
        loop = asyncio.get_running_loop()
        # Schedule the properly-locked async release
        loop.create_task(release_model_slot_async(key))
    except RuntimeError:
        # No running loop - do best-effort sync release
        # This path should be rare (mainly for cleanup during shutdown)
        state = _state.model_states.get(key)
        if state is not None:
            state.active_count = max(0, state.active_count - 1)


def is_circuit_open(model_name: str) -> bool:
    """Check whether the circuit breaker is OPEN for *model_name*.

    Used to prevent wasted retry attempts against rate-limited endpoints.
    If the circuit is open, requests are queued until the cooldown elapses
    and the circuit transitions to HALF_OPEN.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local state.

    Args:
        model_name: The model to check circuit state for.

    Returns:
        ``True`` if the circuit is OPEN and requests would be queued.
        ``False`` if circuit is CLOSED or HALF_OPEN (requests allowed).
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return False  # Unknown model = no throttling

    # Try Elixir bridge first if connected
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_rate_limiter,
            is_connected,
        )

        if is_connected():
            try:
                # Try to get circuit status from Elixir (with short timeout)
                result = asyncio.run(
                    call_elixir_rate_limiter(
                        "rate_limiter.circuit_status",
                        {"model_name": model_name},
                        timeout=1.0,
                    )
                )
                if result.get("status") == "ok" and "circuit_open" in result:
                    return bool(result["circuit_open"])
            except Exception:
                pass  # Fallback to local on any error
    except ImportError:
        pass

    # Fallback to local state
    state = _state.model_states.get(key)
    if state is None:
        return False  # No state = no circuit yet

    return (
        _state.cfg_circuit_breaker_enabled and state.circuit_state == CircuitState.OPEN
    )


def check_model_slot(model_name: str) -> bool:
    """Check whether a concurrency slot is available for *model_name* **without acquiring it**.

    This is a non-consuming preview — useful for UI status indicators,
    load-balancing decisions, or pre-flight checks before committing to
    a request.

    Inspired by ruflo's ``SlidingWindowRateLimiter.check()`` which
    separates "would this be allowed?" from "use a token".

    Args:
        model_name: The model to check availability for.

    Returns:
        ``True`` if ``acquire_model_slot`` would succeed immediately
        (i.e., active_count < current_limit and circuit is not OPEN).
        ``False`` otherwise.

    Note:
        This is inherently racy — the result may be stale by the time
        the caller acts on it. Use for advisory/display purposes only.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return True  # Unknown model = no throttling

    state = _state.model_states.get(key)
    if state is None:
        return True  # No state = no throttling yet

    # Check circuit breaker first
    if _state.cfg_circuit_breaker_enabled and state.circuit_state == CircuitState.OPEN:
        return False

    # Check concurrency slot availability
    return state.active_count < math.ceil(state.current_limit)


def get_current_limit(model_name: str) -> float:
    """Get the current concurrency limit for *model_name*.

    Returns the current adaptive limit for the model. If the model has
    not been rate-limited, returns the initial limit.

    Bridge-aware - tries Elixir bridge first if connected,
    falls back to local state.

    Args:
        model_name: The model to get limit for.

    Returns:
        Current concurrency limit for the model (0 if unknown).
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return 0.0

    # Try Elixir bridge first if connected
    try:
        import asyncio

        from code_puppy.plugins.elixir_bridge import (
            call_elixir_rate_limiter,
            is_connected,
        )

        if is_connected():
            try:
                # Try to get limit from Elixir (with short timeout)
                # Use run_async_sync pattern for sync-in-async scenario
                result = asyncio.run(
                    call_elixir_rate_limiter(
                        "rate_limiter.get_limit",
                        {"model_name": model_name},
                        timeout=1.0,
                    )
                )
                if result.get("status") == "ok" and "limit" in result:
                    return float(result["limit"])
            except Exception:
                pass  # Fallback to local on any error
    except ImportError:
        pass

    # Fallback to local state
    state = _state.model_states.get(key)
    if state is None:
        return float(_state.cfg_initial_limit)
    return state.current_limit


def get_model_semaphore(model_name: str) -> ModelRateLimitState | None:
    """Return the per-model state, or ``None`` if the model is not tracked.

    .. deprecated::
        Use :func:`get_status` for a clean snapshot, or access
        ``_state.model_states`` directly in tests.
    """
    key = _normalize_model_name(model_name)
    if key is None:
        return None
    return _state.model_states.get(key)


def get_status() -> dict[str, dict[str, Any]]:
    """Return a snapshot of all tracked models and their current limits.

    Example::

        {
            "gpt-4": {
                "current_limit": 5.0,
                "active_count": 2,
                "total_429_count": 2,
                "last_429_time": 1719999999.123,
                "in_cooldown": True,
                "circuit_state": "open",
                "queue_depth": 3,
            },
        }
    """
    now = time.monotonic()
    result: dict[str, dict[str, Any]] = {}
    for model_name, st in _state.model_states.items():
        in_cooldown = (
            st.last_429_time is not None
            and (now - st.last_429_time) < _state.cfg_cooldown_seconds
        )
        queue_depth = st.request_queue.qsize() if st.request_queue is not None else 0
        result[model_name] = {
            "current_limit": st.current_limit,
            "active_count": st.active_count,
            "total_429_count": st.total_429_count,
            "last_429_time": st.last_429_time,
            "in_cooldown": in_cooldown,
            "circuit_state": st.circuit_state.value,
            "queue_depth": queue_depth,
        }
    return result


def reset() -> None:
    """Clear **all** per-model state and cancel the recovery task.

    Intended for use in tests and interactive sessions.
    """
    if _state.recovery_task is not None:
        _state.recovery_task.cancel()
        _state.recovery_task = None
    for task in _state.circuit_tasks:
        task.cancel()
    _state.circuit_tasks.clear()
    _state.model_states.clear()
    _state.recovery_started = False

    # Restore defaults
    _state.reset_to_defaults()


def reset_state_for_tests() -> None:
    """Reset the adaptive rate limiter state for test isolation.

    Clears all per-model state and cancels the recovery task.
    This is an alias for reset() provided for consistency with
    other singleton reset helpers.
    """
    reset()


# ── Context manager ─────────────────────────────────────────────────────────


class ModelAwareLimiter:
    """Async context manager that acquires/releases an adaptive slot.

    Usage::

        async with ModelAwareLimiter("gpt-4"):
            await make_api_call(...)
    """

    def __init__(self, model_name: str) -> None:
        self._model_name = model_name
        self._state: ModelRateLimitState | None = None

    async def __aenter__(self) -> ModelAwareLimiter:
        await acquire_model_slot(self._model_name)
        key = self._model_name.lower().strip()
        self._state = _state.model_states.get(key)
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: Any,
    ) -> bool:
        if self._state is not None:
            async with self._state.condition:
                self._state.active_count = max(0, self._state.active_count - 1)
                self._state.last_used_time = time.monotonic()  # Track for cleanup
                self._state.condition.notify_all()
        return False


# ── Backward compatibility ──────────────────────────────────────────────────
#
# Tests and external code reference legacy module-level names like
# ``arl._cfg_min_limit``, ``arl._model_states``, and
# ``arl._recovery_started = True``. We replace the module object in
# ``sys.modules`` with a thin wrapper that delegates those names to the
# ``_state`` singleton, preserving full backward compatibility without
# keeping any actual global variables.

_STATE_ALIASES: dict[str, str] = {
    "_model_states": "model_states",
    "_lock": "lock",
    "_recovery_task": "recovery_task",
    "_recovery_started": "recovery_started",
    "_circuit_tasks": "circuit_tasks",
    "_cfg_min_limit": "cfg_min_limit",
    "_cfg_max_limit": "cfg_max_limit",
    "_cfg_cooldown_seconds": "cfg_cooldown_seconds",
    "_cfg_recovery_rate": "cfg_recovery_rate",
    "_cfg_initial_limit": "cfg_initial_limit",
    "_cfg_circuit_breaker_enabled": "cfg_circuit_breaker_enabled",
    "_cfg_circuit_cooldown_seconds": "cfg_circuit_cooldown_seconds",
    "_cfg_circuit_half_open_requests": "cfg_circuit_half_open_requests",
    "_cfg_queue_max_size": "cfg_queue_max_size",
    "_cfg_release_rate": "cfg_release_rate",
}

import sys as _sys  # noqa: E402
from types import ModuleType as _ModuleType  # noqa: E402


class _BackCompatModule(_ModuleType):
    """Module wrapper that delegates legacy global names to ``_state``."""

    def __getattr__(self, name: str) -> Any:
        if name in _STATE_ALIASES:
            return getattr(_state, _STATE_ALIASES[name])
        raise AttributeError(f"module {self.__name__!r} has no attribute {name!r}")

    def __setattr__(self, name: str, value: Any) -> None:
        if name in _STATE_ALIASES:
            setattr(_state, _STATE_ALIASES[name], value)
        else:
            _ModuleType.__setattr__(self, name, value)


_old = _sys.modules[__name__]
_new = _BackCompatModule(_old.__name__)
_new.__file__ = getattr(_old, "__file__", None)
_new.__loader__ = getattr(_old, "__loader__", None)
_new.__package__ = getattr(_old, "__package__", None)
_new.__spec__ = getattr(_old, "__spec__", None)
_new.__doc__ = _old.__doc__

# Copy every module-level definition into the new module wrapper,
# except the backward-compat plumbing itself.
_SKIP = frozenset(
    {
        "_BackCompatModule",
        "_old",
        "_new",
        "_STATE_ALIASES",
        "_SKIP",
        "_sys",
        "_ModuleType",
    }
)
for _attr, _val in list(vars(_old).items()):
    if _attr in _SKIP:
        continue
    _ModuleType.__setattr__(_new, _attr, _val)

_sys.modules[__name__] = _new
