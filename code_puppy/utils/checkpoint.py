"""Incremental JSONL checkpointing for resumable batch operations.

Provides a simple ``CheckpointStore`` that persists completed work items
to a JSONL file, enabling resume-after-crash for long-running API-heavy
batch jobs.

Inspired by Agentless ``utils.py:70-85`` (``load_existing_instance_ids``)
and ``localize.py:401-436`` (``skip_existing`` pattern).

Usage:
    store = CheckpointStore("/tmp/batch_results.jsonl")
    for item in work_items:
        if store.is_done(item["id"]):
            continue  # Skip already-processed items
        result = process(item)
        store.save(item["id"], result)

Thread-safe: Multiple threads can call ``save()`` concurrently.
"""

import json
import logging
import threading
from pathlib import Path
from typing import Any, Iterator

logger = logging.getLogger(__name__)


class CheckpointStore:
    """JSONL-backed checkpoint store for resumable batch processing.

    On construction, loads any existing checkpoint file and builds an
    in-memory set of completed IDs. New completions are appended
    atomically (one JSON line per ``save()`` call).

    Thread-safe via a lock on writes. Reads from the in-memory set
    are lock-free after initial load.

    Attributes:
        path: Path to the JSONL checkpoint file.

    Examples:
        >>> import tempfile, os
        >>> path = os.path.join(tempfile.mkdtemp(), "ckpt.jsonl")
        >>> store = CheckpointStore(path)
        >>> store.is_done("task-1")
        False
        >>> store.save("task-1", {"status": "ok"})
        >>> store.is_done("task-1")
        True
        >>> store.count
        1
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._lock = threading.Lock()
        self._done: set[str] = set()
        self._results: dict[str, Any] = {}
        self._load_existing()

    def _load_existing(self) -> None:
        """Load completed IDs from existing checkpoint file."""
        if not self.path.exists():
            return

        loaded = 0
        errors = 0
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                for line_num, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        item_id = entry.get("_checkpoint_id")
                        if item_id is not None:
                            self._done.add(str(item_id))
                            self._results[str(item_id)] = entry.get("result")
                            loaded += 1
                        else:
                            errors += 1
                    except json.JSONDecodeError:
                        errors += 1
                        continue
        except OSError as exc:
            logger.warning("checkpoint: could not read %s: %s", self.path, exc)
            return

        if loaded > 0:
            logger.info(
                "checkpoint: loaded %d completed items from %s (%d skipped)",
                loaded,
                self.path,
                errors,
            )

    def is_done(self, item_id: str) -> bool:
        """Check if an item has already been processed.

        Thread-safe O(1) lookup against the in-memory set.

        Args:
            item_id: Unique identifier for the work item.

        Returns:
            True if the item was previously saved.
        """
        with self._lock:
            return str(item_id) in self._done

    def get_result(self, item_id: str) -> Any | None:
        """Retrieve the saved result for a completed item.

        Args:
            item_id: Unique identifier for the work item.

        Returns:
            The saved result, or None if not found.
        """
        with self._lock:
            return self._results.get(str(item_id))

    def save(self, item_id: str, result: Any = None) -> None:
        """Save a completed item to the checkpoint file.

        Appends a single JSON line atomically. Thread-safe.

        Args:
            item_id: Unique identifier for the work item.
            result: Optional result data to persist alongside the ID.
        """
        item_id = str(item_id)
        entry = {
            "_checkpoint_id": item_id,
            "result": result,
        }

        with self._lock:
            # Write atomically (single line append)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, default=str) + "\n")

            # Update in-memory state
            self._done.add(item_id)
            self._results[item_id] = result

    @property
    def count(self) -> int:
        """Number of completed items."""
        return len(self._done)

    @property
    def done_ids(self) -> frozenset[str]:
        """Immutable snapshot of completed item IDs."""
        return frozenset(self._done)

    def iter_results(self) -> Iterator[tuple[str, Any]]:
        """Iterate over (item_id, result) pairs.

        Yields:
            Tuples of (item_id, result) for all completed items.
        """
        for item_id in sorted(self._done):
            yield item_id, self._results.get(item_id)

    def clear(self) -> None:
        """Clear all checkpoints (in-memory and on disk).

        Truncates the checkpoint file if it exists.
        """
        with self._lock:
            self._done.clear()
            self._results.clear()
            if self.path.exists():
                try:
                    self.path.write_text("", encoding="utf-8")
                except OSError as exc:
                    logger.warning("checkpoint: could not clear %s: %s", self.path, exc)
