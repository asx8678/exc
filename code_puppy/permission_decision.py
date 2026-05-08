"""Typed permission decision for tool operations.

Replaces raw ``bool`` / ``dict`` returns from ``on_file_permission`` and
``on_run_shell_command`` callbacks with a single, inspectable sealed type.

Before (two inconsistent patterns):
    # file_modifications.py
    if any(not r for r in results if r is not None):   # bool check

    # command_runner.py
    if isinstance(r, dict) and r.get("blocked"):       # dict check

After (one pattern everywhere):
    for result in results:
        if isinstance(result, Deny):
            return rejection_response(result.user_feedback)

Design notes
------------
- All three variants are frozen dataclasses so they are hashable and
  safe to pass across async boundaries.
- ``user_feedback`` on ``Deny`` carries the human-readable message that
  was previously smuggled back through thread-local storage in the
  ``file_permission_handler`` plugin.  The tool layer now reads it
  directly, removing the plugin→tool import inversion.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Allow:
    """The operation is permitted; proceed without further prompting."""


@dataclass(frozen=True)
class Deny:
    """The operation is denied.

    Attributes:
        reason: Machine-readable reason surfaced to the model.
        user_feedback: Optional human-readable feedback to include in the
            rejection message sent back to the model.
    """

    reason: str
    user_feedback: str | None = None


@dataclass(frozen=True)
class AskUser:
    """Defer the decision to an interactive user prompt.

    Reserved for future use — hooks that need to escalate to the user
    *after* returning from the callback can return this instead of
    blocking inside the callback itself.

    Attributes:
        prompt: Question / context to show the user.
    """

    prompt: str


# Union alias — use ``isinstance(x, Deny)`` etc., not a match statement,
# for compatibility with Python 3.9.
PermissionDecision = Allow | Deny | AskUser
