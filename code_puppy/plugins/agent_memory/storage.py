"""File-based storage module for agent memory.

Provides thread-safe, per-agent fact storage with graceful
handling of corrupt or missing data files.
"""

import json
import logging
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from code_puppy.config_paths import (
    resolve_path,
    safe_atomic_write,
    safe_mkdir_p,
    safe_write,
)

logger = logging.getLogger(__name__)


# Base storage location: respects pup-ex isolation (ADR-003)
def _memory_dir() -> Path:
    """Return the memory directory under the active home."""
    return resolve_path("memory")


# Fact schema: {text: str, confidence: float, source_session: str, created_at: str, last_reinforced: str}
Fact = dict[str, Any]


class FileMemoryStorage:
    """Thread-safe file-based storage for agent memory facts.

    Each agent gets its own JSON file at ~/.code_puppy/memory/<agent_name>.json
    Facts are stored as a list of dictionaries with metadata.

    Attributes:
        agent_name: The name of the agent (determines storage file)
        _file_path: Path to the agent's JSON storage file
        _lock: Threading lock for concurrent access safety
    """

    def __init__(self, agent_name: str) -> None:
        """Initialize storage for a specific agent.

        Args:
            agent_name: The name of the agent (e.g., "turbo-executor")

        Raises:
            ValueError: If agent_name is empty or contains path separators
        """
        if not agent_name or not agent_name.strip():
            raise ValueError("agent_name cannot be empty")
        # Prevent directory traversal or invalid filenames
        if "/" in agent_name or "\\" in agent_name or ".." in agent_name:
            raise ValueError(f"Invalid agent_name: {agent_name}")

        self.agent_name = agent_name
        self._file_path = _memory_dir() / f"{agent_name}.json"
        self._lock = threading.Lock()

    def _ensure_directory(self) -> None:
        """Ensure the memory directory exists."""
        safe_mkdir_p(_memory_dir())

    def _backup_corrupt_file(self) -> None:
        """Backup a corrupt JSON file before resetting."""
        if not self._file_path.exists():
            return

        try:
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
            # Use .json.bak suffix before any existing suffixes
            backup_name = f"{self._file_path.stem}.corrupt.{timestamp}.json.bak"
            backup_path = self._file_path.parent / backup_name
            safe_write(backup_path, self._file_path.read_text(encoding="utf-8"))
            logger.warning(
                "Corrupt memory file for %s backed up to %s",
                self.agent_name,
                backup_path,
            )
        except Exception as e:
            logger.error("Failed to backup corrupt memory file: %s", e)

    def _load_unlocked(self) -> list[Fact]:
        """Internal load without lock - caller must hold lock."""
        if not self._file_path.exists():
            return []

        try:
            with open(self._file_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            if not isinstance(data, list):
                logger.warning(
                    "Invalid memory data for %s: expected list, got %s",
                    self.agent_name,
                    type(data).__name__,
                )
                self._backup_corrupt_file()
                return []

            # Validate each fact has required fields
            valid_facts = []
            for fact in data:
                if isinstance(fact, dict) and "text" in fact:
                    valid_facts.append(fact)
                else:
                    logger.debug(
                        "Skipping invalid fact in %s memory: %s",
                        self.agent_name,
                        fact,
                    )

            return valid_facts

        except json.JSONDecodeError as e:
            logger.error(
                "Corrupt JSON in memory file for %s: %s",
                self.agent_name,
                e,
            )
            self._backup_corrupt_file()
            return []
        except (IOError, OSError) as e:
            logger.error(
                "Failed to read memory file for %s: %s",
                self.agent_name,
                e,
            )
            return []

    def _save_unlocked(self, facts: list[Fact]) -> None:
        """Internal save without lock - caller must hold lock."""
        self._ensure_directory()

        try:
            safe_atomic_write(
                self._file_path,
                json.dumps(facts, indent=2, ensure_ascii=False),
            )
        except (IOError, OSError) as e:
            logger.error(
                "Failed to save memory file for %s: %s",
                self.agent_name,
                e,
            )

    def load(self) -> list[Fact]:
        """Load all facts from storage.

        Returns:
            List of facts, empty list if file doesn't exist or is corrupt.

        Thread-safe: Yes
        """
        with self._lock:
            return self._load_unlocked()

    def save(self, facts: list[Fact]) -> None:
        """Save all facts to storage (overwrites existing).

        Args:
            facts: List of fact dictionaries to save

        Thread-safe: Yes
        """
        with self._lock:
            self._save_unlocked(facts)

    def add_fact(self, fact: Fact) -> None:
        """Add a single fact to storage.

        Args:
            fact: Fact dictionary with at least a 'text' key.
                  Recommended: {text, confidence, source_session, created_at, last_reinforced}

        Thread-safe: Yes
        """
        if not isinstance(fact, dict) or "text" not in fact:
            logger.warning(
                "Invalid fact format for %s: missing 'text' key", self.agent_name
            )
            return

        # Use batch method for efficiency (single write)
        self.add_facts([fact])

    def add_facts(self, facts: list[Fact]) -> int:
        """Add multiple facts to storage in a single batch operation.

        This is more efficient than calling add_fact() multiple times as it
        performs only one file read and one file write for the entire batch.

        Args:
            facts: List of fact dictionaries to add

        Returns:
            Number of facts actually added (invalid facts are skipped)

        Thread-safe: Yes
        """
        if not facts:
            return 0

        # Validate and filter facts
        valid_facts = []
        for fact in facts:
            if isinstance(fact, dict) and "text" in fact:
                valid_facts.append(fact)
            else:
                logger.debug(
                    "Skipping invalid fact in %s memory: %s", self.agent_name, fact
                )

        if not valid_facts:
            return 0

        with self._lock:
            existing_facts = self._load_unlocked()
            existing_facts.extend(valid_facts)
            self._save_unlocked(existing_facts)

        return len(valid_facts)

    def remove_fact(self, text: str) -> bool:
        """Remove the first fact matching the given text.

        Args:
            text: The exact text of the fact to remove

        Returns:
            True if a fact was removed, False if not found

        Thread-safe: Yes
        """
        removed = self.remove_facts([text])
        return bool(removed)

    def remove_facts(self, texts: list[str]) -> list[str]:
        """Remove multiple facts by their text in a single batch operation.

        This is more efficient than calling remove_fact() multiple times as it
        performs only one file read and one file write for the entire batch.

        Args:
            texts: List of fact texts to remove

        Returns:
            List of fact texts that were actually removed

        Thread-safe: Yes
        """
        if not texts:
            return []

        texts_set = set(texts)  # O(1) lookup
        removed_texts: list[str] = []

        with self._lock:
            facts = self._load_unlocked()
            original_count = len(facts)

            # Filter out matching facts and track which were removed
            new_facts = []
            removed_in_pass: set[str] = set()

            for fact in facts:
                fact_text = fact.get("text", "")
                if fact_text in texts_set and fact_text not in removed_in_pass:
                    removed_texts.append(fact_text)
                    removed_in_pass.add(fact_text)  # Only remove first match per text
                else:
                    new_facts.append(fact)

            if len(new_facts) < original_count:
                self._save_unlocked(new_facts)

        return removed_texts

    def clear(self) -> None:
        """Clear all facts for this agent.

        Thread-safe: Yes
        """
        with self._lock:
            self._save_unlocked([])

    def get_facts(self, min_confidence: float = 0.0) -> list[Fact]:
        """Get all facts with optional confidence filtering.

        Args:
            min_confidence: Minimum confidence threshold (0.0 to 1.0)

        Returns:
            List of facts meeting the confidence threshold

        Thread-safe: Yes
        """
        facts = self.load()

        if min_confidence <= 0.0:
            return facts

        return [f for f in facts if f.get("confidence", 1.0) >= min_confidence]

    def fact_count(self) -> int:
        """Return the number of stored facts.

        Returns:
            Number of facts in storage

        Thread-safe: Yes
        """
        return len(self.load())

    def update_fact(self, text: str, updates: dict[str, Any]) -> bool:
        """Update fields of an existing fact.

        Args:
            text: The exact text of the fact to update
            updates: Dictionary of fields to update

        Returns:
            True if the fact was found and updated, False otherwise

        Thread-safe: Yes
        """
        result = self.update_facts({text: updates})
        return bool(result)

    def update_facts(self, updates: dict[str, dict[str, Any]]) -> list[str]:
        """Update multiple facts in a single batch operation.

        This is more efficient than calling update_fact() multiple times as it
        performs only one file read and one file write for the entire batch.

        Args:
            updates: Dictionary mapping fact text to update dictionaries

        Returns:
            List of fact texts that were successfully updated

        Thread-safe: Yes
        """
        if not updates:
            return []

        updated_texts: list[str] = []

        with self._lock:
            facts = self._load_unlocked()
            facts_by_text = {f.get("text"): f for f in facts if f.get("text")}

            for text, update_data in updates.items():
                if text in facts_by_text:
                    facts_by_text[text].update(update_data)
                    updated_texts.append(text)

            if updated_texts:
                self._save_unlocked(facts)

        return updated_texts

    def reinforce_fact(self, text: str, session_id: str | None = None) -> bool:
        """Reinforce a fact by updating its last_reinforced timestamp.

        This is used when a fact is encountered again, strengthening
        its position in the agent's memory.

        Args:
            text: The exact text of the fact to reinforce
            session_id: Optional session ID where reinforcement occurred

        Returns:
            True if the fact was found and reinforced, False otherwise

        Thread-safe: Yes
        """
        with self._lock:
            facts = self._load_unlocked()

            for fact in facts:
                if fact.get("text") == text:
                    fact["last_reinforced"] = datetime.now(timezone.utc).isoformat()
                    if session_id:
                        fact["source_session"] = session_id
                    self._save_unlocked(facts)
                    return True

            return False
