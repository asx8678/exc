"""JSON-backed prompt template store with locked defaults + user overrides.

This module provides thread-safe persistence for prompt templates,
supporting both locked built-in defaults and editable user templates.
"""

import json
import logging
import threading
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from code_puppy.config_paths import resolve_path, safe_atomic_write, safe_write

logger = logging.getLogger(__name__)


# Respects pup-ex isolation (ADR-003) — resolves under active home
def _default_store_path() -> Path:
    """Return the prompt store path under the active home."""
    from code_puppy.config_package.env_helpers import get_first_env

    override = get_first_env("PUPPY_PROMPT_STORE")
    if override:
        return Path(override).expanduser().resolve()
    return resolve_path("prompt_store.json")


def __getattr__(name: str):
    """Lazy resolution of env-sensitive module-level names."""
    if name == "DEFAULT_STORE_PATH":
        return _default_store_path()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


@dataclass
class PromptTemplate:
    """A single prompt template.

    Attributes:
        id: Unique identifier (e.g., "code-puppy.custom-1" or user-provided)
        name: Human-friendly display name
        agent_name: Which agent this prompt applies to (e.g., "code-puppy")
        content: The actual system prompt text
        source: "default" (locked) or "user" (editable)
        locked: True for built-in defaults that cannot be modified
        created_at: ISO 8601 timestamp when created
        updated_at: ISO 8601 timestamp when last modified
    """

    id: str
    name: str
    agent_name: str
    content: str
    source: str  # "default" or "user"
    locked: bool
    created_at: str
    updated_at: str

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PromptTemplate:
        """Create from dictionary."""
        return cls(
            id=data["id"],
            name=data["name"],
            agent_name=data["agent_name"],
            content=data["content"],
            source=data.get("source", "user"),
            locked=data.get("locked", False),
            created_at=data["created_at"],
            updated_at=data["updated_at"],
        )


class PromptStore:
    """JSON-backed prompt template store with locked defaults + user overrides.

    Thread-safe operations with atomic file writes. Malformed JSON files are
    backed up and the store starts fresh.
    """

    def __init__(self, store_path: Path | None = None) -> None:
        """Initialize the store.

        Args:
            store_path: Path to the JSON store file. If None, uses default.
        """
        self.store_path = store_path or _default_store_path()
        self._lock = threading.Lock()
        self._templates: dict[str, PromptTemplate] = {}
        self._active: dict[str, str] = {}  # agent_name -> template_id
        self._load()

    def _load(self) -> None:
        """Load templates from disk.

        If the file doesn't exist, starts with empty store.
        If the file is malformed, backs it up and starts fresh.
        """
        if not self.store_path.exists():
            logger.debug(f"Store file doesn't exist: {self.store_path}")
            return

        try:
            with open(self.store_path, encoding="utf-8") as f:
                data = json.load(f)

            for tmpl_dict in data.get("templates", []):
                try:
                    tmpl = PromptTemplate.from_dict(tmpl_dict)
                    self._templates[tmpl.id] = tmpl
                except (KeyError, TypeError) as e:
                    logger.warning(f"Skipping malformed template: {e}")

            self._active = data.get("active", {})
            logger.debug(f"Loaded {len(self._templates)} templates from store")

        except json.JSONDecodeError as e:
            logger.warning(f"Malformed JSON in store file: {e}")
            self._backup_and_reset()
        except Exception as e:
            logger.error(f"Error loading store: {e}")
            self._backup_and_reset()

    def _backup_and_reset(self) -> None:
        """Backup the broken store file and start fresh."""
        backup_path = self.store_path.with_suffix(".json.bak")
        try:
            safe_write(
                backup_path,
                self.store_path.read_text(encoding="utf-8", errors="surrogateescape"),
                encoding="utf-8",
            )
            logger.info(f"Backed up broken store to {backup_path}")
        except Exception as e:
            logger.warning(f"Failed to backup broken store: {e}")
        # Reset to empty state
        self._templates = {}
        self._active = {}

    def _save(self) -> None:
        """Save templates to disk atomically.

        Writes to a temp file then renames for atomicity.
        """
        data = {
            "templates": [tmpl.to_dict() for tmpl in self._templates.values()],
            "active": self._active,
        }

        try:
            safe_atomic_write(self.store_path, json.dumps(data, indent=2))
            logger.debug(f"Saved {len(self._templates)} templates to store")
        except Exception as e:
            logger.error(f"Error saving store: {e}")
            raise

    def list_templates(self, agent_name: str | None = None) -> list[PromptTemplate]:
        """List all templates, optionally filtered by agent_name.

        Args:
            agent_name: If provided, only templates for this agent

        Returns:
            List of PromptTemplate objects
        """
        with self._lock:
            templates = list(self._templates.values())
            if agent_name:
                templates = [t for t in templates if t.agent_name == agent_name]
            return sorted(templates, key=lambda t: (t.agent_name, t.name))

    def get_template(self, template_id: str) -> PromptTemplate | None:
        """Fetch a template by ID.

        Args:
            template_id: The unique template identifier

        Returns:
            PromptTemplate or None if not found
        """
        with self._lock:
            return self._templates.get(template_id)

    def get_active_for_agent(self, agent_name: str) -> PromptTemplate | None:
        """Get the currently active custom template for an agent.

        Args:
            agent_name: The agent to check

        Returns:
            PromptTemplate or None if no active template
        """
        with self._lock:
            template_id = self._active.get(agent_name)
            if template_id:
                return self._templates.get(template_id)
            return None

    def set_active_for_agent(self, agent_name: str, template_id: str) -> None:
        """Mark a template as active for an agent.

        Args:
            agent_name: The agent to set active template for
            template_id: The template ID to activate

        Raises:
            ValueError: If template_id doesn't exist
        """
        with self._lock:
            if template_id not in self._templates:
                raise ValueError(f"Template not found: {template_id}")
            self._active[agent_name] = template_id
            self._save()
            logger.debug(f"Set active template for {agent_name}: {template_id}")

    def clear_active_for_agent(self, agent_name: str) -> None:
        """Revert to default by removing the active pointer.

        Args:
            agent_name: The agent to clear active template for
        """
        with self._lock:
            if agent_name in self._active:
                del self._active[agent_name]
                self._save()
                logger.debug(f"Cleared active template for {agent_name}")

    def _generate_id(self, agent_name: str) -> str:
        """Generate a unique template ID.

        Format: <agent_name>.custom-<n>
        """
        base = f"{agent_name}.custom"
        n = 1
        while f"{base}-{n}" in self._templates:
            n += 1
        return f"{base}-{n}"

    def _get_timestamp(self) -> str:
        """Get current ISO 8601 timestamp."""
        return datetime.now(timezone.utc).isoformat()

    def create_template(
        self, name: str, agent_name: str, content: str
    ) -> PromptTemplate:
        """Create a new user template.

        Args:
            name: Human-friendly display name
            agent_name: Which agent this prompt applies to
            content: The system prompt text

        Returns:
            The created PromptTemplate

        Raises:
            ValueError: If agent_name is empty or content is empty
        """
        if not agent_name.strip():
            raise ValueError("agent_name is required")
        if not content.strip():
            raise ValueError("content is required")

        with self._lock:
            template_id = self._generate_id(agent_name)
            now = self._get_timestamp()
            tmpl = PromptTemplate(
                id=template_id,
                name=name,
                agent_name=agent_name,
                content=content,
                source="user",
                locked=False,
                created_at=now,
                updated_at=now,
            )
            self._templates[template_id] = tmpl
            self._save()
            logger.info(f"Created template: {template_id}")
            return tmpl

    def update_template(
        self,
        template_id: str,
        *,
        name: str | None = None,
        content: str | None = None,
    ) -> PromptTemplate:
        """Update a user template.

        Args:
            template_id: The template to update
            name: New display name (optional)
            content: New prompt content (optional)

        Returns:
            The updated PromptTemplate

        Raises:
            ValueError: If template is locked or not found
        """
        with self._lock:
            tmpl = self._templates.get(template_id)
            if tmpl is None:
                raise ValueError(f"Template not found: {template_id}")
            if tmpl.locked:
                raise ValueError(f"Template is locked: {template_id}")

            if name is not None:
                tmpl.name = name
            if content is not None:
                tmpl.content = content
            tmpl.updated_at = self._get_timestamp()

            self._save()
            logger.info(f"Updated template: {template_id}")
            return tmpl

    def delete_template(self, template_id: str) -> bool:
        """Delete a user template.

        Args:
            template_id: The template to delete

        Returns:
            True if deleted, False if not found

        Raises:
            ValueError: If template is locked
        """
        with self._lock:
            tmpl = self._templates.get(template_id)
            if tmpl is None:
                return False
            if tmpl.locked:
                raise ValueError(f"Template is locked: {template_id}")

            del self._templates[template_id]

            # Also clear from active if it was active
            for agent, tid in list(self._active.items()):
                if tid == template_id:
                    del self._active[agent]

            self._save()
            logger.info(f"Deleted template: {template_id}")
            return True

    def duplicate_template(self, source_id: str, new_name: str) -> PromptTemplate:
        """Create an editable copy of any template (including locked defaults).

        Args:
            source_id: The template to duplicate
            new_name: The display name for the new template

        Returns:
            The new PromptTemplate (unlocked, source="user")

        Raises:
            ValueError: If source template not found
        """
        with self._lock:
            source = self._templates.get(source_id)
            if source is None:
                raise ValueError(f"Source template not found: {source_id}")

            new_id = self._generate_id(source.agent_name)
            now = self._get_timestamp()
            new_tmpl = PromptTemplate(
                id=new_id,
                name=new_name,
                agent_name=source.agent_name,
                content=source.content,
                source="user",  # Duplicates are always user-editable
                locked=False,
                created_at=now,
                updated_at=now,
            )
            self._templates[new_id] = new_tmpl
            self._save()
            logger.info(f"Duplicated {source_id} as {new_id}")
            return new_tmpl

    def get_store_path(self) -> Path:
        """Return the path to the store file."""
        return self.store_path
