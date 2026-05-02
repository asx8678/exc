"""RunContext for hierarchical tracing and execution context management.

This module provides structured run context for tracking execution hierarchies
in agent runs, tool calls, and other operations. It integrates with contextvars
for safe async context propagation.
"""

from __future__ import annotations

import contextvars
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

# ContextVar for the current run context - thread/async safe
_current_run_context: contextvars.ContextVar[RunContext | None] = (
    contextvars.ContextVar("current_run_context", default=None)
)


@dataclass
class RunContext:
    """Execution context for a single run/operation.

    RunContext tracks metadata for execution units like agent runs,
    tool invocations, model calls, etc. It supports parent-child
    relationships for tracing hierarchical operations.

    Attributes:
        run_id: Unique identifier for this run
        parent_run_id: Parent run ID if this is a child operation
        session_id: Session identifier for grouping related runs
        component_type: Type of component (agent/tool/model/plugin)
        component_name: Name of the component being executed
        tags: List of string tags for categorization
        metadata: Additional key-value metadata
        start_time: Unix timestamp when run started
        end_time: Unix timestamp when run ended (None if ongoing)
        success: Whether run completed successfully (None if ongoing)
        error_type: Type of exception if failed (None if success or ongoing)
    """

    run_id: str
    component_type: str
    component_name: str
    parent_run_id: str | None = None
    session_id: str | None = None
    tags: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    start_time: float = field(default_factory=time.time)
    end_time: float | None = None
    success: bool | None = None
    error_type: str | None = None

    def end(self, success: bool = True, error: Exception | None = None) -> None:
        """Mark the run as ended with status.

        Args:
            success: Whether the run completed successfully
            error: Exception if the run failed
        """
        self.end_time = time.time()
        self.success = success
        if error is not None:
            self.error_type = type(error).__name__

    @property
    def duration_ms(self) -> float | None:
        """Calculate duration in milliseconds.

        Returns:
            Duration if run has ended, None otherwise
        """
        if self.end_time is None:
            return None
        return (self.end_time - self.start_time) * 1000

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary representation.

        Returns:
            Dict with all context fields
        """
        return {
            "run_id": self.run_id,
            "parent_run_id": self.parent_run_id,
            "session_id": self.session_id,
            "component_type": self.component_type,
            "component_name": self.component_name,
            "tags": self.tags,
            "metadata": self.metadata,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "duration_ms": self.duration_ms,
            "success": self.success,
            "error_type": self.error_type,
        }

    @classmethod
    def create_child(
        cls,
        parent: RunContext,
        component_type: str,
        component_name: str,
        **kwargs: Any,
    ) -> RunContext:
        """Create a child run context from a parent.

        Args:
            parent: Parent run context
            component_type: Type of child component
            component_name: Name of child component
            **kwargs: Additional fields to set on child context

        Returns:
            New child RunContext with parent_run_id set
        """
        # Inherit tags from parent if not explicitly provided
        tags = kwargs.pop("tags", list(parent.tags))
        # Start with empty metadata if not explicitly provided
        metadata = kwargs.pop("metadata", {})

        return cls(
            run_id=str(uuid.uuid4()),
            parent_run_id=parent.run_id,
            session_id=parent.session_id,
            component_type=component_type,
            component_name=component_name,
            tags=tags,
            metadata=metadata,
            **kwargs,
        )


def get_current_run_context() -> RunContext | None:
    """Get the current run context for this execution context.

    This is safe to use across async boundaries due to ContextVar.

    Returns:
        Current RunContext or None if not set
    """
    return _current_run_context.get()


def set_current_run_context(ctx: RunContext | None) -> contextvars.Token:
    """Set the current run context.

    Args:
        ctx: RunContext to set, or None to clear

    Returns:
        Token for restoring previous context
    """
    return _current_run_context.set(ctx)


def reset_run_context(token: contextvars.Token) -> None:
    """Reset run context using token from set_current_run_context.

    Args:
        token: Token returned by set_current_run_context
    """
    _current_run_context.reset(token)


def create_root_run_context(
    component_type: str,
    component_name: str,
    session_id: str | None = None,
    tags: list[str] | None = None,
    metadata: dict[str, Any] | None = None,
) -> RunContext:
    """Create a new root run context.

    This is typically called at the start of an agent run or top-level operation.

    Args:
        component_type: Type of component (agent/tool/model/etc)
        component_name: Name of the component
        session_id: Optional session ID to group related runs
        tags: Optional list of tags
        metadata: Optional initial metadata

    Returns:
        New RunContext with generated run_id
    """
    return RunContext(
        run_id=str(uuid.uuid4()),
        component_type=component_type,
        component_name=component_name,
        session_id=session_id,
        tags=tags or [],
        metadata=metadata or {},
    )


# Convenience function for creating child context and setting it
@dataclass
class RunContextManager:
    """Context manager for run context lifecycle.

    Handles setting/restoring context and marking end state.
    Works with both sync `with` and async `async with`.

    Example:
        with RunContextManager("tool", "read_file", session_id="abc") as ctx:
            result = read_file(...)
            # ctx automatically marked as success on exit
    """

    component_type: str
    component_name: str
    session_id: str | None = None
    parent_context: RunContext | None = None
    tags: list[str] | None = None  # None means inherit from parent if available
    metadata: dict[str, Any] = field(default_factory=dict)
    _ctx: RunContext | None = field(init=False, default=None)
    _token: contextvars.Token | None = field(init=False, default=None)

    def __enter__(self) -> RunContext:
        """Enter context, create and set RunContext."""
        if self.parent_context is not None:
            # Inherit parent tags if no explicit tags provided
            effective_tags = self.tags
            if effective_tags is None:
                effective_tags = list(self.parent_context.tags)

            self._ctx = RunContext.create_child(
                self.parent_context,
                self.component_type,
                self.component_name,
                tags=effective_tags,
                metadata=self.metadata,
            )
        else:
            self._ctx = create_root_run_context(
                self.component_type,
                self.component_name,
                self.session_id,
                self.tags or [],
                self.metadata,
            )

        self._token = set_current_run_context(self._ctx)
        return self._ctx

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Exit context, mark end state and restore previous context."""
        if self._ctx is not None:
            success = exc_val is None
            self._ctx.end(success=success, error=exc_val)

        if self._token is not None:
            reset_run_context(self._token)

    async def __aenter__(self) -> RunContext:
        """Async enter - delegates to sync enter."""
        return self.__enter__()

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        """Async exit - delegates to sync exit."""
        return self.__exit__(exc_type, exc_val, exc_tb)
