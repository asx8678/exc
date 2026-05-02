"""Agent Trace V2 — NDJSON Persistence.

Simple append-only storage for trace events. Events are written
as newline-delimited JSON for easy streaming and replay.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Iterator

from code_puppy.config_paths import (
    assert_write_allowed,
    resolve_path,
    safe_append,
    safe_mkdir_p,
    safe_rm,
)
from code_puppy.plugins.agent_trace.schema import TraceEvent

logger = logging.getLogger(__name__)


class TraceStore:
    """Append-only NDJSON store for trace events.

    Events are stored in files named by trace_id:
        ~/.code_puppy/traces/{trace_id}.ndjson

    This enables:
    - Replay of past runs
    - Comparison between runs
    - Post-hoc analysis and aggregation
    """

    def __init__(self, base_dir: Path | str | None = None):
        """Initialize the trace store.

        Args:
            base_dir: Directory for trace files. Defaults to ~/.code_puppy/traces/
        """
        if base_dir is None:
            base_dir = resolve_path("traces")

        assert_write_allowed(base_dir, "trace_store_init")
        self.base_dir = Path(base_dir)
        self._ensure_dir()

    def _ensure_dir(self) -> None:
        """Ensure the trace directory exists."""
        try:
            safe_mkdir_p(self.base_dir)
        except OSError as e:
            logger.warning(f"Failed to create trace directory: {e}")

    def _trace_path(self, trace_id: str) -> Path:
        """Get the file path for a trace."""
        # Sanitize trace_id for filesystem safety
        safe_id = "".join(c if c.isalnum() or c in "-_" else "_" for c in trace_id)
        return self.base_dir / f"{safe_id}.ndjson"

    def append(self, event: TraceEvent) -> bool:
        """Append an event to its trace file.

        Returns True if successful, False otherwise.
        """
        if not event.trace_id:
            logger.debug("Cannot store event without trace_id")
            return False

        try:
            path = self._trace_path(event.trace_id)
            safe_append(path, event.to_json() + "\n", encoding="utf-8")
            return True
        except OSError as e:
            logger.debug(f"Failed to append event: {e}")
            return False

    def append_batch(self, events: list[TraceEvent]) -> int:
        """Append multiple events, grouped by trace_id.

        Returns count of successfully written events.
        """
        # Group by trace_id for efficient file access
        by_trace: dict[str, list[TraceEvent]] = {}
        for event in events:
            if event.trace_id:
                by_trace.setdefault(event.trace_id, []).append(event)

        written = 0
        for trace_id, trace_events in by_trace.items():
            try:
                path = self._trace_path(trace_id)
                safe_append(
                    path,
                    "".join(event.to_json() + "\n" for event in trace_events),
                    encoding="utf-8",
                )
                written += len(trace_events)
            except OSError as e:
                logger.debug(f"Failed to write batch for {trace_id}: {e}")

        return written

    def read(self, trace_id: str) -> list[TraceEvent]:
        """Read all events for a trace.

        Returns empty list if trace doesn't exist or can't be read.
        """
        path = self._trace_path(trace_id)
        if not path.exists():
            return []

        events = []
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            events.append(TraceEvent.from_json(line))
                        except (json.JSONDecodeError, KeyError) as e:
                            logger.debug(f"Skipping malformed event: {e}")
        except OSError as e:
            logger.debug(f"Failed to read trace {trace_id}: {e}")

        return events

    def stream(self, trace_id: str) -> Iterator[TraceEvent]:
        """Stream events for a trace (memory-efficient for large traces)."""
        path = self._trace_path(trace_id)
        if not path.exists():
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            yield TraceEvent.from_json(line)
                        except json.JSONDecodeError, KeyError:
                            continue
        except OSError:
            return

    def list_traces(self) -> list[str]:
        """List all available trace IDs."""
        try:
            return [p.stem for p in self.base_dir.glob("*.ndjson")]
        except OSError:
            return []

    def delete(self, trace_id: str) -> bool:
        """Delete a trace file."""
        path = self._trace_path(trace_id)
        try:
            if path.exists():
                safe_rm(path)
            return True
        except OSError as e:
            logger.debug(f"Failed to delete trace {trace_id}: {e}")
            return False

    def size(self, trace_id: str) -> int:
        """Get the size of a trace file in bytes."""
        path = self._trace_path(trace_id)
        try:
            return path.stat().st_size if path.exists() else 0
        except OSError:
            return 0

    def event_count(self, trace_id: str) -> int:
        """Count events in a trace (requires reading the file)."""
        path = self._trace_path(trace_id)
        if not path.exists():
            return 0

        try:
            with open(path, "r", encoding="utf-8") as f:
                return sum(1 for line in f if line.strip())
        except OSError:
            return 0
