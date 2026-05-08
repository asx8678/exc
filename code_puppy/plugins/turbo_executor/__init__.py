"""Turbo Executor Plugin — Batch file operations orchestrator.

Provides high-performance batch execution of file operations (list_files, grep, read_files)
with a structured plan schema and result collection.
"""

from code_puppy.plugins.turbo_executor.models import (
    Operation,
    OperationResult,
    OperationType,
    Plan,
    PlanResult,
    PlanStatus,
)
from code_puppy.plugins.turbo_executor.orchestrator import TurboOrchestrator
from code_puppy.plugins.turbo_executor.summarizer import (
    quick_summary,
    summarize_operation_result,
    summarize_plan_result,
)

__all__ = [
    "Operation",
    "OperationResult",
    "OperationType",
    "Plan",
    "PlanResult",
    "PlanStatus",
    "TurboOrchestrator",
    "summarize_plan_result",
    "summarize_operation_result",
    "quick_summary",
]
