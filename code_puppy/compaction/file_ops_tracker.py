"""Track file operations across message history for compaction summaries.

Ported from pi-mono-main packages/coding-agent/src/core/compaction/utils.ts.
Extracts read/write/edit tool calls from messages and formats them as XML
tags that are appended to compaction summaries.

This ensures the model retains awareness of which files were touched even
after older messages are compacted away.
"""

from dataclasses import dataclass, field

__all__ = [
    "FileOpsTracker",
    "extract_file_ops_from_messages",
    "format_file_ops_xml",
]


@dataclass
class FileOpsTracker:
    """Accumulates file operations across compaction boundaries.

    Maintains three sets: read files, written files, and edited files.
    Operations accumulate across multiple compaction rounds so the
    summary always reflects the complete file access history.
    """

    read: set[str] = field(default_factory=set)
    written: set[str] = field(default_factory=set)
    edited: set[str] = field(default_factory=set)

    def add_read(self, path: str) -> None:
        self.read.add(path)

    def add_write(self, path: str) -> None:
        self.written.add(path)

    def add_edit(self, path: str) -> None:
        self.edited.add(path)

    def merge(self, other: FileOpsTracker) -> None:
        """Merge another tracker's operations into this one."""
        self.read |= other.read
        self.written |= other.written
        self.edited |= other.edited

    @property
    def read_files(self) -> list[str]:
        """Sorted list of read files."""
        return sorted(self.read)

    @property
    def modified_files(self) -> list[str]:
        """Sorted list of modified files (written + edited, deduplicated)."""
        return sorted(self.written | self.edited)

    @property
    def has_ops(self) -> bool:
        """Whether any operations have been tracked."""
        return bool(self.read or self.written or self.edited)

    def clear(self) -> None:
        """Reset all tracked operations."""
        self.read.clear()
        self.written.clear()
        self.edited.clear()


def extract_file_ops_from_messages(
    messages: list,  # list[ModelMessage] from pydantic_ai
    tracker: FileOpsTracker | None = None,
) -> FileOpsTracker:
    """Extract file operation metadata from a list of LLM messages.

    Scans assistant messages for tool calls that operate on files,
    extracting the file path from tool call arguments.

    Recognized tool names and their argument keys:
    - read_file, read: "file_path", "path"
    - write_to_file, write_file, create_file, write: "path", "file_path"
    - replace_in_file, edit_file, edit, apply_patch: "path", "file_path"
    - delete_snippet_from_file: "file_path"
    - grep, search: "directory" (optional, tracks search scope)

    Args:
        messages: List of pydantic-ai ModelMessage objects.
        tracker: Optional existing tracker to accumulate into.

    Returns:
        FileOpsTracker with all extracted operations.
    """
    if tracker is None:
        tracker = FileOpsTracker()

    # Tool name -> operation type mapping
    _READ_TOOLS = frozenset(
        {
            "read_file",
            "read",
        }
    )
    _WRITE_TOOLS = frozenset(
        {
            "write_to_file",
            "write_file",
            "create_file",
            "write",
        }
    )
    _EDIT_TOOLS = frozenset(
        {
            "replace_in_file",
            "edit_file",
            "edit",
            "apply_patch",
            "delete_snippet_from_file",
        }
    )
    _PATH_KEYS = ("file_path", "path")

    try:
        from pydantic_ai.messages import (
            ModelResponse,
            ToolCallPart,
        )
    except ImportError:
        return tracker  # Graceful degradation if pydantic-ai not available

    for msg in messages:
        if not isinstance(msg, ModelResponse):
            continue
        for part in msg.parts:
            if not isinstance(part, ToolCallPart):
                continue

            tool_name = part.tool_name
            args = part.args

            # Extract path from args (could be dict or ArgsDict)
            path = None
            if isinstance(args, dict):
                for key in _PATH_KEYS:
                    if key in args:
                        path = args[key]
                        break

            if not path or not isinstance(path, str):
                continue

            # Classify the operation
            if tool_name in _READ_TOOLS:
                tracker.add_read(path)
            elif tool_name in _WRITE_TOOLS:
                tracker.add_write(path)
            elif tool_name in _EDIT_TOOLS:
                tracker.add_edit(path)

    return tracker


def format_file_ops_xml(tracker: FileOpsTracker) -> str:
    """Format tracked file operations as XML tags for compaction summaries.

    Produces XML like:
        <read-files>
        - src/main.py
        - src/utils.py
        </read-files>
        <modified-files>
        - src/config.py
        </modified-files>

    Returns empty string if no operations were tracked.

    Args:
        tracker: FileOpsTracker with accumulated operations.

    Returns:
        XML-formatted string, or empty string if no ops.
    """
    if not tracker.has_ops:
        return ""

    parts = []

    read_files = tracker.read_files
    if read_files:
        lines = "\n".join(f"- {f}" for f in read_files)
        parts.append(f"<read-files>\n{lines}\n</read-files>")

    modified_files = tracker.modified_files
    if modified_files:
        lines = "\n".join(f"- {f}" for f in modified_files)
        parts.append(f"<modified-files>\n{lines}\n</modified-files>")

    return "\n".join(parts)
