"""Fixed-capacity circular (ring) buffer.

Inspired by oh-my-pi's ring.ts
(packages/utils/src/ring.ts in the omp project).

A RingBuffer holds at most *capacity* items in O(1) for all operations.
When the buffer is full, push() evicts the oldest item (head) and
unshift() evicts the newest item (tail).
"""

from typing import Iterator, overload


class RingBuffer[T]:
    """Fixed-capacity circular buffer with O(1) push/pop/shift/unshift.

    Internally the buffer is stored as a pre-allocated list together with
    a *head* pointer and a *size* counter.  No Python ``deque`` is used so
    that random-access via ``at()`` / ``__getitem__`` is O(1).

    Inspired by oh-my-pi's ring.ts (packages/utils/src/ring.ts).

    Example::

        buf = RingBuffer(3)
        buf.push(1)
        buf.push(2)
        buf.push(3)
        evicted = buf.push(4)  # evicted == 1
        list(buf)              # [2, 3, 4]
    """

    __slots__ = ("_buf", "_head", "_size", "_capacity")

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def __init__(self, capacity: int) -> None:
        """Create an empty ring buffer that holds at most *capacity* items.

        Args:
            capacity: Maximum number of items.  Must be ≥ 1.

        Raises:
            ValueError: If *capacity* is less than 1.
        """
        if capacity < 1:
            raise ValueError(f"capacity must be >= 1, got {capacity!r}")
        self._capacity: int = capacity
        self._buf: list = [None] * capacity
        self._head: int = 0
        self._size: int = 0

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def capacity(self) -> int:
        """Maximum number of items the buffer can hold (read-only)."""
        return self._capacity

    @property
    def is_full(self) -> bool:
        """``True`` when ``len(self) == self.capacity``."""
        return self._size == self._capacity

    @property
    def is_empty(self) -> bool:
        """``True`` when the buffer contains no items."""
        return self._size == 0

    # ------------------------------------------------------------------
    # Mutation – tail operations
    # ------------------------------------------------------------------

    def push(self, item: T) -> T | None:
        """Append *item* to the **end** (tail) of the buffer.

        If the buffer is already full the oldest item (head) is evicted
        and returned; otherwise ``None`` is returned.

        Args:
            item: The item to add.

        Returns:
            The evicted item when full, or ``None``.
        """
        if self._size == self._capacity:
            # Full – overwrite head position (oldest) with new item.
            evicted: T = self._buf[self._head]
            self._buf[self._head] = item
            self._head = (self._head + 1) % self._capacity
            return evicted

        tail = (self._head + self._size) % self._capacity
        self._buf[tail] = item
        self._size += 1
        return None

    def pop(self) -> T | None:
        """Remove and return the **last** (newest) item.

        Returns:
            The last item, or ``None`` if the buffer is empty.
        """
        if self._size == 0:
            return None
        self._size -= 1
        tail = (self._head + self._size) % self._capacity
        val: T = self._buf[tail]
        self._buf[tail] = None  # release reference
        return val

    # ------------------------------------------------------------------
    # Mutation – head operations
    # ------------------------------------------------------------------

    def shift(self) -> T | None:
        """Remove and return the **first** (oldest) item.

        Returns:
            The first item, or ``None`` if the buffer is empty.
        """
        if self._size == 0:
            return None
        val: T = self._buf[self._head]
        self._buf[self._head] = None  # release reference
        self._head = (self._head + 1) % self._capacity
        self._size -= 1
        return val

    def unshift(self, item: T) -> T | None:
        """Prepend *item* to the **beginning** (head) of the buffer.

        If the buffer is already full the newest item (tail) is evicted
        and returned; otherwise ``None`` is returned.

        Args:
            item: The item to prepend.

        Returns:
            The evicted item when full, or ``None``.
        """
        new_head = (self._head - 1 + self._capacity) % self._capacity
        if self._size == self._capacity:
            # Full – the tail slot (which is new_head after the wrap) is evicted.
            evicted: T = self._buf[new_head]
            self._buf[new_head] = item
            self._head = new_head
            return evicted

        self._buf[new_head] = item
        self._head = new_head
        self._size += 1
        return None

    # ------------------------------------------------------------------
    # Non-destructive accessors
    # ------------------------------------------------------------------

    def at(self, index: int) -> T | None:
        """Return the item at logical *index* without removing it.

        Supports negative indices (``-1`` is the last item).

        Args:
            index: Logical position.  Supports negative indexing.

        Returns:
            The item at that position, or ``None`` if out-of-range or empty.
        """
        if self._size == 0:
            return None
        if index < 0:
            index += self._size
        if index < 0 or index >= self._size:
            return None
        return self._buf[(self._head + index) % self._capacity]

    def peek(self) -> T | None:
        """Return the **first** (oldest) item without removing it.

        Returns:
            The first item, or ``None`` if empty.
        """
        if self._size == 0:
            return None
        return self._buf[self._head]

    def peek_back(self) -> T | None:
        """Return the **last** (newest) item without removing it.

        Returns:
            The last item, or ``None`` if empty.
        """
        if self._size == 0:
            return None
        return self._buf[(self._head + self._size - 1) % self._capacity]

    # ------------------------------------------------------------------
    # Bulk operations
    # ------------------------------------------------------------------

    def clear(self) -> None:
        """Remove all items and reset the buffer to empty state."""
        # Release references to allow GC.
        for i in range(self._size):
            self._buf[(self._head + i) % self._capacity] = None
        self._head = 0
        self._size = 0

    def to_list(self) -> list[T]:
        """Return a snapshot of all items in logical order (oldest first).

        Returns:
            A new list; mutations do **not** affect the buffer.
        """
        return [self._buf[(self._head + i) % self._capacity] for i in range(self._size)]

    # ------------------------------------------------------------------
    # Python data-model
    # ------------------------------------------------------------------

    def __len__(self) -> int:
        """Return the current number of items."""
        return self._size

    def __bool__(self) -> bool:
        """``True`` when the buffer is non-empty."""
        return self._size > 0

    def __iter__(self) -> Iterator[T]:
        """Iterate over items in logical order (oldest → newest)."""
        for i in range(self._size):
            yield self._buf[(self._head + i) % self._capacity]

    @overload
    def __getitem__(self, index: int) -> T | None: ...

    @overload
    def __getitem__(self, index: slice) -> list[T]: ...

    def __getitem__(self, index: int | slice) -> T | None | list[T]:
        """Support index and slice access (read-only).

        Args:
            index: An integer index (negative supported) or a ``slice``.

        Returns:
            Single item for integer index (``None`` if out-of-range),
            or a list for a slice.
        """
        if isinstance(index, slice):
            return [self.at(i) for i in range(*index.indices(self._size))]
        return self.at(index)

    def __repr__(self) -> str:
        items = self.to_list()
        return (
            f"RingBuffer(capacity={self._capacity}, size={self._size}, items={items!r})"
        )
