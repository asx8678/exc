"""Post-edit syntax validation helpers.

This module previously routed to a native tree-sitter backend (turbo_parse).
After removing the native acceleration layer, validation is a no-op stub.
The real syntax validation now lives on the Elixir side via
CodePuppyControl.Parsing.Parser, but no Python bridge endpoint exists yet
(filed as future work). Until that endpoint exists, validate_file_sync
returns PARSER_UNAVAILABLE which is fail-open.

Cleaned up dead native-backend branches.

Usage:

    result = validate_file_sync(path="foo.py", content=new_content, timeout_s=0.5)
    if result.status is ValidationStatus.INVALID:
        # Surface result.errors back to the agent
        ...
"""

import logging
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger(__name__)

PARSER_TIMEOUT_S = 0.5  # matches plandex's 500ms


class ValidationStatus(str, Enum):
    VALID = "valid"
    INVALID = "invalid"
    TIMED_OUT = "timed_out"
    PARSER_UNAVAILABLE = "parser_unavailable"


@dataclass(slots=True)
class ValidationResult:
    status: ValidationStatus
    errors: list[str] = field(default_factory=list)
    language: str | None = None

    @property
    def is_valid(self) -> bool:
        """Return True if the result should be treated as "not a hard failure".

        VALID, PARSER_UNAVAILABLE, and TIMED_OUT are all fail-open.
        Only INVALID should block/warn.
        """
        return self.status is not ValidationStatus.INVALID


def validate_file_sync(
    path: str,
    content: str,
    *,
    timeout_s: float = PARSER_TIMEOUT_S,
) -> ValidationResult:
    """Synchronously validate file content, failing open on any error.

    This is the main entrypoint. Native acceleration removed,
    always returns PARSER_UNAVAILABLE (fail-open).
    """
    # No Python-side parser available; see module docstring.
    return ValidationResult(status=ValidationStatus.PARSER_UNAVAILABLE)


async def validate_file_async(
    path: str,
    content: str,
    *,
    timeout_s: float = PARSER_TIMEOUT_S,
) -> ValidationResult:
    """Async variant that runs the sync validator in the default executor."""
    import asyncio

    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(
        None,
        lambda: validate_file_sync(path, content, timeout_s=timeout_s),
    )


def format_validation_errors_for_agent(result: ValidationResult) -> str | None:
    """Render a validation result as a short warning string for the agent.

    Returns None if the result is fine (valid, timed out, or parser-unavailable).
    """
    if result.is_valid:
        return None
    if not result.errors:
        return "⚠️ Syntax validation detected an issue but provided no details."
    lines = ["⚠️ Syntax validation found issues after your edit:"]
    for err in result.errors[:5]:  # cap at 5
        lines.append(f" - {err}")
    if len(result.errors) > 5:
        lines.append(f" ... and {len(result.errors) - 5} more")
    lines.append("Consider checking the file and fixing any syntax errors.")
    return "\n".join(lines)
