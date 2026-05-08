"""Plan schema models for Turbo Executor.

Defines the JSON structure for batch file operations:
- Plan: id, operations[], metadata
- Operation: type, args, priority
"""

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field, field_validator


class OperationType(str, Enum):
    """Supported operation types for turbo execution."""

    LIST_FILES = "list_files"
    GREP = "grep"
    READ_FILES = "read_files"


class PlanStatus(str, Enum):
    """Status of a plan execution."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    PARTIAL = "partial"  # Some operations failed
    FAILED = "failed"


class Operation(BaseModel):
    """Single operation within a plan.

    Attributes:
        type: The operation type (list_files, grep, read_files)
        args: Operation-specific arguments
        priority: Execution priority (lower = earlier, default 100)
        id: Optional unique identifier for the operation
    """

    type: OperationType
    args: dict[str, Any] = Field(default_factory=dict)
    priority: int = Field(default=100, ge=0, le=1000)
    id: str | None = None

    @field_validator("args")
    @classmethod
    def validate_args_for_type(cls, args: dict, info) -> dict:
        """Validate that required args are present for each operation type."""
        op_type = info.data.get("type")
        if not op_type:
            return args

        if op_type == OperationType.LIST_FILES:
            # directory is optional, defaults to "."
            args.setdefault("directory", ".")
            args.setdefault("recursive", True)

        elif op_type == OperationType.GREP:
            # search_string is required
            if "search_string" not in args:
                raise ValueError("grep operation requires 'search_string' in args")
            args.setdefault("directory", ".")

        elif op_type == OperationType.READ_FILES:
            # file_paths is required (list of files to read)
            if "file_paths" not in args:
                raise ValueError("read_files operation requires 'file_paths' in args")
            if not isinstance(args["file_paths"], list):
                raise ValueError("read_files 'file_paths' must be a list")

        return args


class Plan(BaseModel):
    """A plan containing multiple operations to execute.

    Attributes:
        id: Unique identifier for the plan
        operations: List of operations to execute
        metadata: Optional metadata (description, tags, etc.)
        max_parallel: Maximum parallel operations (currently unused, for future)
    """

    id: str
    operations: list[Operation] = Field(default_factory=list)
    metadata: dict[str, Any] = Field(default_factory=dict)
    max_parallel: int = Field(default=1, ge=1, le=10)

    @field_validator("operations")
    @classmethod
    def sort_by_priority(cls, ops: list[Operation]) -> list[Operation]:
        """Sort operations by priority (ascending)."""
        return sorted(ops, key=lambda op: op.priority)


class OperationResult(BaseModel):
    """Result of executing a single operation.

    Attributes:
        operation_id: ID of the operation (if provided)
        type: Operation type
        status: Success/failure status
        data: Operation-specific result data
        error: Error message if failed
        duration_ms: Execution time in milliseconds
    """

    operation_id: str | None = None
    type: OperationType
    status: str = "success"  # "success" or "error"
    data: dict[str, Any] = Field(default_factory=dict)
    error: str | None = None
    duration_ms: float = 0.0


class PlanResult(BaseModel):
    """Result of executing a plan.

    Attributes:
        plan_id: ID of the executed plan
        status: Overall execution status
        operation_results: List of individual operation results
        started_at: ISO timestamp when execution started
        completed_at: ISO timestamp when execution completed
        total_duration_ms: Total execution time
        metadata: Summary metadata
    """

    plan_id: str
    status: PlanStatus
    operation_results: list[OperationResult] = Field(default_factory=list)
    started_at: str | None = None
    completed_at: str | None = None
    total_duration_ms: float = 0.0
    metadata: dict[str, Any] = Field(default_factory=dict)

    @property
    def success_count(self) -> int:
        """Count of successful operations."""
        return sum(1 for r in self.operation_results if r.status == "success")

    @property
    def error_count(self) -> int:
        """Count of failed operations."""
        return sum(1 for r in self.operation_results if r.status == "error")

    def get_errors(self) -> list[OperationResult]:
        """Get all failed operations."""
        return [r for r in self.operation_results if r.status == "error"]
