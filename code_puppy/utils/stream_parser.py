"""Line-oriented streaming parsers for SSE and JSONL streams.

Inspired by patterns from oh-my-pi (omp) project.

These parsers are designed to work with incremental byte/text chunks
coming off a network socket – they never block and accumulate internal
state between calls.
"""

import json
from collections.abc import Generator
from dataclasses import dataclass
from typing import Any

# ---------------------------------------------------------------------------
# Low-level line parser
# ---------------------------------------------------------------------------


class StreamLineParser:
    """Buffer incoming text chunks and emit complete lines.

    Chunks may arrive with partial lines at the boundaries.  The parser
    keeps a carry-over buffer and only yields lines once the terminating
    ``\\n`` (or ``\\r\\n``) arrives.

    Example::

        parser = StreamLineParser()
        for line in parser.feed("hel"):
            ...  # nothing yet
        for line in parser.feed("lo\\nworld\\n"):
            print(line)  # "hello" then "world"
        for line in parser.flush():
            print(line)  # any leftover without final newline
    """

    __slots__ = ("_buf",)

    def __init__(self) -> None:
        self._buf: str = ""

    def feed(self, chunk: str) -> Generator[str, None, None]:
        """Feed a text chunk; yield complete lines (without trailing newline).

        Args:
            chunk: Arbitrary text fragment.

        Yields:
            Complete lines in arrival order.
        """
        self._buf += chunk
        while True:
            idx = self._buf.find("\n")
            if idx == -1:
                break
            line = self._buf[:idx].rstrip("\r")
            self._buf = self._buf[idx + 1 :]
            yield line

    def flush(self) -> Generator[str, None, None]:
        """Yield any buffered text as a final (possibly incomplete) line.

        Yields:
            The remaining buffer if non-empty.
        """
        if self._buf:
            yield self._buf.rstrip("\r")
            self._buf = ""

    def reset(self) -> None:
        """Discard internal buffer."""
        self._buf = ""


# ---------------------------------------------------------------------------
# Server-Sent Events parser
# ---------------------------------------------------------------------------


@dataclass
class SSEEvent:
    """A single Server-Sent Event."""

    event: str = "message"
    data: str = ""
    id: str | None = None
    retry: int | None = None


class SSEParser:
    """Parse a Server-Sent Events stream from raw text chunks.

    Internally delegates to :class:`StreamLineParser` for line extraction,
    then applies the SSE field-dispatch logic defined in the HTML spec.

    Example::

        parser = SSEParser()
        for event in parser.feed("event: ping\\ndata: hello\\n\\n"):
            print(event.event, event.data)  # "ping" "hello"
    """

    def __init__(self) -> None:
        self._line_parser = StreamLineParser()
        self._current: dict[str, str] = {}

    def feed(self, chunk: str) -> Generator[SSEEvent, None, None]:
        """Feed a chunk of raw SSE text; yield complete events.

        Args:
            chunk: Raw text fragment from the HTTP response body.

        Yields:
            :class:`SSEEvent` objects as complete event blocks arrive.
        """
        for line in self._line_parser.feed(chunk):
            event = self._process_line(line)
            if event is not None:
                yield event

    def _process_line(self, line: str) -> SSEEvent | None:
        if not line:
            # Empty line dispatches the event.
            if self._current:
                evt = SSEEvent(
                    event=self._current.get("event", "message"),
                    data=self._current.get("data", ""),
                    id=self._current.get("id"),
                    retry=int(self._current["retry"])
                    if "retry" in self._current
                    else None,
                )
                self._current = {}
                return evt
            return None

        if line.startswith(":"):
            # Comment line – ignore.
            return None

        if ":" in line:
            field, _, value = line.partition(":")
            value = value.lstrip(" ")
        else:
            field, value = line, ""

        if field == "data":
            existing = self._current.get("data", "")
            self._current["data"] = (existing + "\n" + value) if existing else value
        elif field in ("event", "id", "retry"):
            self._current[field] = value

        return None


# ---------------------------------------------------------------------------
# JSONL / lenient JSON helpers
# ---------------------------------------------------------------------------


def parse_jsonl_lenient(text: str) -> list[Any]:
    """Parse a JSONL (JSON Lines) string, skipping malformed lines.

    Each non-empty line is attempted as JSON.  Lines that fail to parse
    are silently dropped rather than raising an exception, which is
    useful when processing streaming API responses that may include
    non-JSON status lines.

    Args:
        text: Multi-line string where each line may be a JSON value.

    Returns:
        List of successfully parsed values in line order.
    """
    results: list[Any] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            results.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return results
