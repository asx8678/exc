"""History offload: append evicted messages to a timestamped log file.

When summarization compacts old messages, this helper preserves them by appending
to a per-session log file with section headers. Useful for debugging and audit.

Opt-in via config key `summarization_history_offload_enabled` (default: False).
"""

import logging
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Any, Sequence

from code_puppy.config_paths import (
    assert_write_allowed,
    resolve_path,
    safe_append,
    safe_mkdir_p,
)
from code_puppy.utils.path_safety import (
    PathSafetyError,
    safe_path_component,
    verify_contained,
)

if TYPE_CHECKING:
    pass

logger = logging.getLogger(__name__)

_offload_lock = threading.Lock()


# Respects pup-ex isolation (ADR-003) — resolves under active home
def _default_archive_dir() -> Path:
    """Return the history archive directory under the active home."""
    return resolve_path("history")


def __getattr__(name: str):
    """Lazy resolution of env-sensitive module-level names."""
    if name == "DEFAULT_ARCHIVE_DIR":
        return _default_archive_dir()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


DEFAULT_MAX_ARCHIVE_SIZE_MB = 100  # Default max archive size before rotation


def _sanitize_session_id(session_id: str | None) -> str:
    """Sanitize session ID for use as a filename.

    Uses the shared path_safety.safe_path_component() utility when possible
    for consistent strict validation. Falls back to character replacement
    for backwards compatibility with existing archives that may contain dots.

    Note: Dots are preserved in the fallback for backwards compatibility,
    but the final path is still verified with verify_contained() before use.

    Args:
        session_id: Session ID string, or None.

    Returns:
        Sanitized session ID safe for use as a filename.
    """
    # Handle None safely
    if session_id is None:
        return "unknown"

    # Try using the strict allowlist validation first (no dots allowed)
    try:
        return safe_path_component(session_id)
    except PathSafetyError:
        # Fallback: replace unsafe chars with underscores for backwards compat
        # Allow dots in this fallback for backwards compatibility with archives
        # that use version strings like "my-session_test.v1"
        safe_chars = set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        result = ""
        for c in session_id:
            if c in safe_chars:
                result += c
            elif c == ".":
                # Preserve dots for backwards compatibility (e.g., version strings)
                result += c
            else:
                result += "_"

        # Handle edge case: result is empty after replacement
        if not result:
            return "unknown"

        # Handle edge case: result contains traversal patterns (e.g., "..")
        # These should be sanitized to prevent path traversal
        if ".." in result:
            result = result.replace("..", "__")

        # Enforce max length
        if len(result) > 64:
            result = result[:64]

        return result


def _get_archive_size_mb(archive_path: Path) -> float:
    """Get the size of an archive file in megabytes.

    Args:
        archive_path: Path to the archive file.

    Returns:
        Size in megabytes, or 0.0 if file doesn't exist.
    """
    if not archive_path.exists():
        return 0.0
    return archive_path.stat().st_size / (1024 * 1024)


def _rotate_archive(archive_path: Path) -> None:
    """Rotate an archive file by renaming it with a timestamp suffix.

    The existing archive is renamed to {name}.{timestamp}.history.md,
    effectively starting a new archive file.

    Args:
        archive_path: Path to the archive file to rotate.
    """
    if not archive_path.exists():
        return

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    rotated_name = (
        archive_path.stem.replace(".history", f"_{timestamp}.history")
        + archive_path.suffix
    )
    rotated_path = archive_path.parent / rotated_name

    try:
        assert_write_allowed(archive_path, "history_rotate_source")
        assert_write_allowed(rotated_path, "history_rotate_dest")
        archive_path.rename(rotated_path)
        logger.debug("Rotated archive %s to %s", archive_path, rotated_path)
    except OSError as e:
        logger.warning("Failed to rotate archive %s: %s", archive_path, e)


def _enforce_archive_size_limit(
    archive_path: Path,
    max_size_mb: float,
) -> None:
    """Enforce archive size limit by rotating if necessary.

    If the archive exceeds the size limit, it is rotated to make room.

    Args:
        archive_path: Path to the archive file.
        max_size_mb: Maximum size in megabytes before rotation.
    """
    current_size = _get_archive_size_mb(archive_path)
    if current_size > max_size_mb:
        logger.debug(
            "Archive %s size (%.2f MB) exceeds limit (%.2f MB), rotating",
            archive_path,
            current_size,
            max_size_mb,
        )
        _rotate_archive(archive_path)


def _serialize_message(msg: Any) -> str:
    """Best-effort human-readable serialization of a single message."""
    try:
        # Try to extract role and content from common message types
        role = None
        content = None

        # pydantic-ai ModelRequest / ModelResponse
        if hasattr(msg, "kind"):
            role = msg.kind
        if hasattr(msg, "parts"):
            # Summarize parts - don't dump huge content
            parts = msg.parts
            if parts:
                part_summaries = []
                for p in parts:
                    if hasattr(p, "part_kind"):
                        pk = p.part_kind
                        if pk == "text":
                            txt = getattr(p, "content", "") or ""
                            part_summaries.append(f"[text: {len(txt)} chars]")
                        elif pk == "tool-call":
                            tn = getattr(p, "tool_name", "unknown")
                            part_summaries.append(f"[tool-call: {tn}]")
                        elif pk == "tool-return":
                            tn = getattr(p, "tool_name", "unknown")
                            part_summaries.append(f"[tool-return: {tn}]")
                        else:
                            part_summaries.append(f"[{pk}]")
                    else:
                        part_summaries.append(str(p)[:100])
                content = ", ".join(part_summaries)

        # Fallback: try common attributes
        if role is None:
            role = getattr(msg, "role", None)
        if content is None:
            content = getattr(msg, "content", None)

        # Final fallback
        if role is None:
            role = type(msg).__name__
        if content is None:
            # Truncate repr to avoid massive dumps
            r = repr(msg)
            content = r[:500] + "..." if len(r) > 500 else r

        return f"**{role}**: {content}"
    except Exception as e:
        return f"**unreadable**: {e}"


def offload_evicted_messages(
    messages: Sequence[Any],
    *,
    session_id: str,
    archive_dir: Path | None = None,
    compact_reason: str = "summarization",
    max_archive_size_mb: float = DEFAULT_MAX_ARCHIVE_SIZE_MB,
) -> Path | None:
    """Append evicted messages to the session's history archive.

    Uses shared path_safety utilities for defense-in-depth against path
    traversal attacks when constructing archive paths from user/LLM input.

    Args:
        messages: The messages being evicted (soon-to-be-replaced by a summary).
        session_id: Unique ID for this session (used as the filename stem).
        archive_dir: Directory for history archives. Defaults to ~/.code_puppy/history/
        compact_reason: Reason for this compaction (appears in the header).
        max_archive_size_mb: Maximum archive size in MB before rotation (default: 100).

    Returns:
        Path to the archive file that was appended to, or None on failure.
    """
    if not messages:
        return None

    archive_dir = archive_dir or _default_archive_dir()

    try:
        # Sanitize session_id to prevent path traversal via filename
        safe_session_id = _sanitize_session_id(session_id)

        # Ensure archive_dir is a Path and create if needed
        archive_dir = Path(archive_dir)
        safe_mkdir_p(archive_dir)

        # Build archive path and verify containment using shared utility
        archive_path = archive_dir / f"{safe_session_id}.history.md"
        try:
            archive_path = verify_contained(archive_path, archive_dir)
        except PathSafetyError as exc:
            logger.warning(
                "Archive path escapes archive_dir; possible traversal: %s", exc
            )
            return None

        timestamp = datetime.now(timezone.utc).isoformat()
        header = f"\n\n## Compacted at {timestamp} (reason: {compact_reason})\n\n"

        # Serialize messages
        body_lines = []
        for msg in messages:
            body_lines.append(_serialize_message(msg))
            body_lines.append("")
        body = "\n".join(body_lines)

        with _offload_lock:
            # Enforce size limit before writing (rotate if necessary)
            _enforce_archive_size_limit(archive_path, max_archive_size_mb)

            safe_append(archive_path, header + body, encoding="utf-8")

        logger.debug("Offloaded %d messages to %s", len(messages), archive_path)
        return archive_path
    except OSError as e:
        # Don't crash summarization because of a filesystem issue
        logger.warning("Failed to offload history to %s: %s", archive_dir, e)
        return None
    except Exception as e:
        logger.warning("Unexpected error during history offload: %s", e)
        return None
