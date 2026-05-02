"""Staged changes sandbox for safe edit application.

This module provides a staging area where AI-generated edits are accumulated,
reviewed, diffed, and then explicitly applied or rejected, instead of
immediately mutating project files.

Features:
- Intercept file modifications (create, replace, delete)
- Store pending changes in memory with full context
- Generate combined diffs for review
- Apply or reject changes as a batch
- Integration with existing file modification tools
"""

import difflib
import hashlib
import json
import logging
import os
import tempfile
import threading
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from enum import Enum, auto
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

STAGE_DIR = Path(tempfile.gettempdir()) / "code_puppy_staged"


class ChangeType(Enum):
    """Types of staged changes."""

    CREATE = auto()
    REPLACE = auto()
    DELETE_SNIPPET = auto()
    DELETE_FILE = auto()


@dataclass
class StagedChange:
    """A single staged change entry."""

    change_id: str
    change_type: ChangeType
    file_path: str

    # For CREATE: new content
    # For REPLACE: old_str and new_str
    # For DELETE_SNIPPET: snippet to delete
    content: str | None = None
    old_str: str | None = None
    new_str: str | None = None
    snippet: str | None = None

    # Metadata
    created_at: float = field(default_factory=time.time)
    description: str = ""
    applied: bool = False
    rejected: bool = False

    def __post_init__(self):
        """Validate that applied and rejected are not both True."""
        if self.applied and self.rejected:
            raise ValueError("StagedChange cannot be both applied and rejected")

    def to_dict(self) -> dict[str, Any]:
        """Serialize change to dictionary."""
        return {
            "change_id": self.change_id,
            "change_type": self.change_type.name,
            "file_path": self.file_path,
            "content": self.content,
            "old_str": self.old_str,
            "new_str": self.new_str,
            "snippet": self.snippet,
            "created_at": self.created_at,
            "description": self.description,
            "applied": self.applied,
            "rejected": self.rejected,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "StagedChange":
        """Create change from dictionary."""
        return cls(
            change_id=data["change_id"],
            change_type=ChangeType[data["change_type"]],
            file_path=data["file_path"],
            content=data.get("content"),
            old_str=data.get("old_str"),
            new_str=data.get("new_str"),
            snippet=data.get("snippet"),
            created_at=data.get("created_at", time.time()),
            description=data.get("description", ""),
            applied=data.get("applied", False),
            rejected=data.get("rejected", False),
        )


class StagedChangesSandbox:
    """Sandbox for accumulating and managing staged file changes."""

    def __init__(self):
        self._lock = threading.Lock()
        self._changes: OrderedDict[str, StagedChange] = OrderedDict()
        self._enabled: bool = False
        self._session_id: str = self._generate_session_id()
        self._ensure_stage_dir()

    def _generate_session_id(self) -> str:
        """Generate unique session ID."""
        return hashlib.sha256(str(time.time()).encode()).hexdigest()[:16]

    def _ensure_stage_dir(self) -> None:
        """Ensure staging directory exists."""
        STAGE_DIR.mkdir(parents=True, exist_ok=True)

    @property
    def enabled(self) -> bool:
        """Check if staging mode is enabled."""
        return self._enabled

    def enable(self) -> None:
        """Enable staging mode."""
        self._enabled = True
        logger.info("Staged changes mode enabled")

    def disable(self) -> None:
        """Disable staging mode (does not clear staged changes)."""
        self._enabled = False
        logger.info("Staged changes mode disabled")

    def toggle(self) -> bool:
        """Toggle staging mode on/off."""
        self._enabled = not self._enabled
        logger.info(f"Staged changes mode {'enabled' if self._enabled else 'disabled'}")
        return self._enabled

    def add_create(
        self, file_path: str, content: str, description: str = ""
    ) -> StagedChange:
        """Stage a file creation."""
        change = StagedChange(
            change_id=self._generate_change_id(),
            change_type=ChangeType.CREATE,
            file_path=os.path.abspath(file_path),
            content=content,
            description=description or f"Create {os.path.basename(file_path)}",
        )
        with self._lock:
            self._changes[change.change_id] = change
        logger.debug(f"Staged create: {file_path}")
        return change

    def add_replace(
        self, file_path: str, old_str: str, new_str: str, description: str = ""
    ) -> StagedChange:
        """Stage a text replacement."""
        change = StagedChange(
            change_id=self._generate_change_id(),
            change_type=ChangeType.REPLACE,
            file_path=os.path.abspath(file_path),
            old_str=old_str,
            new_str=new_str,
            description=description or f"Replace in {os.path.basename(file_path)}",
        )
        with self._lock:
            self._changes[change.change_id] = change
        logger.debug(f"Staged replace: {file_path}")
        return change

    def add_delete_snippet(
        self, file_path: str, snippet: str, description: str = ""
    ) -> StagedChange:
        """Stage a snippet deletion."""
        change = StagedChange(
            change_id=self._generate_change_id(),
            change_type=ChangeType.DELETE_SNIPPET,
            file_path=os.path.abspath(file_path),
            snippet=snippet,
            description=description or f"Delete from {os.path.basename(file_path)}",
        )
        with self._lock:
            self._changes[change.change_id] = change
        logger.debug(f"Staged delete snippet: {file_path}")
        return change

    def _generate_change_id(self) -> str:
        """Generate unique change ID using UUID4."""
        return uuid.uuid4().hex  # 32 hex chars, guaranteed unique

    def get_staged_changes(self, include_applied: bool = False) -> list[StagedChange]:
        """Get all pending staged changes."""
        with self._lock:
            if include_applied:
                return list(self._changes.values())
            return [
                c for c in self._changes.values() if not c.applied and not c.rejected
            ]

    def get_changes_for_file(self, file_path: str) -> list[StagedChange]:
        """Get all staged changes for a specific file."""
        abs_path = os.path.abspath(file_path)
        with self._lock:
            return [
                c
                for c in self._changes.values()
                if c.file_path == abs_path and not c.applied and not c.rejected
            ]

    def clear(self) -> None:
        """Clear all staged changes."""
        with self._lock:
            count = len(self._changes)
            self._changes.clear()
        logger.info(f"Cleared {count} staged changes")

    def remove_change(self, change_id: str) -> bool:
        """Remove a specific change by ID."""
        with self._lock:
            if change_id in self._changes:
                del self._changes[change_id]
                logger.debug(f"Removed change {change_id}")
                return True
        return False

    def count(self) -> int:
        """Count pending staged changes."""
        return len(self.get_staged_changes())

    def is_empty(self) -> bool:
        """Check if no pending staged changes."""
        return self.count() == 0

    def generate_diff(
        self, change: StagedChange, file_cache: dict[str, str] | None = None
    ) -> str:
        """Generate diff for a single change."""
        if change.change_type == ChangeType.CREATE:
            return self._diff_for_create(change)
        elif change.change_type == ChangeType.REPLACE:
            return self._diff_for_replace(change, file_cache)
        elif change.change_type == ChangeType.DELETE_SNIPPET:
            return self._diff_for_delete_snippet(change, file_cache)
        return ""

    def _diff_for_create(self, change: StagedChange) -> str:
        """Generate diff for file creation."""
        content = change.content or ""
        lines = content.splitlines(keepends=True)
        diff = difflib.unified_diff(
            [],
            lines,
            fromfile="/dev/null",
            tofile=f"b/{os.path.basename(change.file_path)}",
            lineterm="",
        )
        return "".join(diff)

    def _diff_for_replace(
        self, change: StagedChange, file_cache: dict[str, str] | None = None
    ) -> str:
        """Generate diff for text replacement."""
        old_str = change.old_str or ""
        new_str = change.new_str or ""

        # Check cache first, then read current file content if it exists
        if file_cache is not None and change.file_path in file_cache:
            original_content = file_cache[change.file_path]
        elif os.path.exists(change.file_path):
            with open(
                change.file_path, "r", encoding="utf-8", errors="surrogateescape"
            ) as f:
                original_content = f.read()
                if file_cache is not None:
                    file_cache[change.file_path] = original_content
        else:
            original_content = ""

        # Apply the replacement
        if old_str in original_content:
            new_content = original_content.replace(old_str, new_str, 1)
        else:
            new_content = original_content

        original_lines = original_content.splitlines(keepends=True)
        new_lines = new_content.splitlines(keepends=True)

        diff = difflib.unified_diff(
            original_lines,
            new_lines,
            fromfile=f"a/{os.path.basename(change.file_path)}",
            tofile=f"b/{os.path.basename(change.file_path)}",
            lineterm="",
        )
        return "".join(diff)

    def _diff_for_delete_snippet(
        self, change: StagedChange, file_cache: dict[str, str] | None = None
    ) -> str:
        """Generate diff for snippet deletion."""
        snippet = change.snippet or ""

        # Check cache first, then read current file content if it exists
        if file_cache is not None and change.file_path in file_cache:
            original_content = file_cache[change.file_path]
        elif os.path.exists(change.file_path):
            with open(
                change.file_path, "r", encoding="utf-8", errors="surrogateescape"
            ) as f:
                original_content = f.read()
                if file_cache is not None:
                    file_cache[change.file_path] = original_content
        else:
            original_content = ""

        # Apply the deletion
        if snippet in original_content:
            new_content = original_content.replace(snippet, "", 1)
        else:
            new_content = original_content

        original_lines = original_content.splitlines(keepends=True)
        new_lines = new_content.splitlines(keepends=True)

        diff = difflib.unified_diff(
            original_lines,
            new_lines,
            fromfile=f"a/{os.path.basename(change.file_path)}",
            tofile=f"b/{os.path.basename(change.file_path)}",
            lineterm="",
        )
        return "".join(diff)

    def generate_combined_diff(self) -> str:
        """Generate combined diff for all pending changes."""
        changes = self.get_staged_changes()
        if not changes:
            return ""

        # Cache file contents to avoid repeated I/O
        file_cache: dict[str, str] = {}

        diffs = []
        for change in changes:
            diff = self.generate_diff(change, file_cache)
            if diff:
                diffs.append(f"# {change.description} ({change.change_id})\n{diff}")

        return "\n\n".join(diffs)

    def preview_changes(self) -> dict[str, str]:
        """Get preview of all changes grouped by file."""
        changes = self.get_staged_changes()
        file_changes: dict[str, list[StagedChange]] = {}

        for change in changes:
            if change.file_path not in file_changes:
                file_changes[change.file_path] = []
            file_changes[change.file_path].append(change)

        result = {}
        for file_path, changes in file_changes.items():
            # Cache file contents per file group to avoid repeated I/O
            file_cache: dict[str, str] = {}
            diffs = [self.generate_diff(c, file_cache) for c in changes]
            result[file_path] = "\n\n".join(diffs)

        return result

    def save_to_disk(self) -> Path:
        """Save staged changes to disk for persistence.

        Uses atomic write-to-tmp-then-rename to avoid corruption if interrupted.

        # FIXME(code-puppy-ctj.5): Triple-write bug — data block repeated 3x.
        # The Elixir port fixes this by writing once.
        """
        self._ensure_stage_dir()
        save_path = STAGE_DIR / f"{self._session_id}.json"

        tmp_path = STAGE_DIR / f"{self._session_id}.json.tmp"

        with self._lock:
            data = {
                "session_id": self._session_id,
                "enabled": self._enabled,
                "changes": [c.to_dict() for c in self._changes.values()],
                "saved_at": time.time(),
            }

        # Atomic write: write to temp file first, then rename
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, save_path)

        logger.info(f"Saved staged changes to {save_path}")
        return save_path

    def load_from_disk(self, session_id: str | None = None) -> bool:
        """Load staged changes from disk."""
        load_id = session_id or self._session_id
        load_path = STAGE_DIR / f"{load_id}.json"

        if not load_path.exists():
            return False

        try:
            with open(load_path, "r") as f:
                data = json.load(f)

            with self._lock:
                self._session_id = data.get("session_id", load_id)
                self._enabled = data.get("enabled", False)
                loaded_changes = [
                    StagedChange.from_dict(c) for c in data.get("changes", [])
                ]
                self._changes = OrderedDict((c.change_id, c) for c in loaded_changes)

            logger.info(f"Loaded {len(self._changes)} staged changes from {load_path}")
            return True
        except Exception as e:
            logger.error(f"Failed to load staged changes: {e}")
            return False

    def get_summary(self) -> dict[str, Any]:
        """Get summary of staged changes."""
        changes = self.get_staged_changes()

        by_type: dict[str, int] = {}
        by_file: dict[str, int] = {}

        for change in changes:
            type_name = change.change_type.name
            by_type[type_name] = by_type.get(type_name, 0) + 1
            by_file[change.file_path] = by_file.get(change.file_path, 0) + 1

        return {
            "total": len(changes),
            "by_type": by_type,
            "by_file": len(by_file),
            "files": list(by_file.keys()),
            "enabled": self._enabled,
            "session_id": self._session_id,
        }


# Global sandbox instance
_sandbox: StagedChangesSandbox | None = None


def get_sandbox() -> StagedChangesSandbox:
    """Get the global staged changes sandbox."""
    global _sandbox
    if _sandbox is None:
        _sandbox = StagedChangesSandbox()
    return _sandbox


def reset_sandbox() -> StagedChangesSandbox:
    """Reset and create new sandbox."""
    global _sandbox
    _sandbox = StagedChangesSandbox()
    return _sandbox


# Convenience functions for external use


def is_staging_enabled() -> bool:
    """Check if staging mode is enabled."""
    return get_sandbox().enabled


def stage_create(file_path: str, content: str, description: str = "") -> StagedChange:
    """Stage a file creation."""
    return get_sandbox().add_create(file_path, content, description)


def stage_replace(
    file_path: str, old_str: str, new_str: str, description: str = ""
) -> StagedChange:
    """Stage a text replacement."""
    return get_sandbox().add_replace(file_path, old_str, new_str, description)


def stage_delete_snippet(
    file_path: str, snippet: str, description: str = ""
) -> StagedChange:
    """Stage a snippet deletion."""
    return get_sandbox().add_delete_snippet(file_path, snippet, description)


def get_staged_count() -> int:
    """Get count of pending staged changes."""
    return get_sandbox().count()


def clear_staged() -> None:
    """Clear all staged changes."""
    get_sandbox().clear()
