"""Git Auto Commit (GAC) Plugin - Safe automated git operations.

This plugin provides automated git commit functionality with strict safety guards
to ensure git mutations only occur in safe, interactive, main-agent contexts.

The context guard module provides hard-fail protection against:
- Sub-agent execution contexts (sub-agents cannot perform git mutations)
- Non-interactive terminals (user confirmation requires TTY)
- Nested agent contexts (depth > 1 is blocked)

The shell bridge module provides a sync→async bridge for executing git commands
through Code Puppy's centralized security boundary.

The commit flow module orchestrates the full commit workflow:
- preflight_check: Detect staged/unstaged changes
- generate_preview: Show what would be committed
- execute_commit: Run git commit through security boundary

Example:
    >>> from code_puppy.plugins.git_auto_commit import check_gac_context
    >>> check_gac_context()  # Raises GACContextError in unsafe contexts

    >>> from code_puppy.plugins.git_auto_commit import is_gac_safe
    >>> is_safe, reason = is_gac_safe()
    >>> if not is_safe:
    ...     print(f"Cannot auto-commit: {reason}")

    >>> from code_puppy.plugins.git_auto_commit import execute_git_command_sync
    >>> result = execute_git_command_sync("git status")
    >>> if result["success"]:
    ...     print(result["output"])

    >>> from code_puppy.plugins.git_auto_commit import preflight_check, generate_preview
    >>> preflight = preflight_check()
    >>> if preflight["has_staged"]:
    ...     preview = generate_preview()
    ...     print(preview["summary"])
"""

# Context guard exports from 7db.8
# Commit flow exports from 7db.3 (M1)
from code_puppy.plugins.git_auto_commit.commit_flow import (
    CommitFlowError,
    execute_commit,
    generate_preview,
    preflight_check,
    run_full_flow,
)
from code_puppy.plugins.git_auto_commit.context_guard import (
    REASON_NESTED_AGENT,
    REASON_NON_INTERACTIVE,
    REASON_SUBAGENT,
    GACContextError,
    check_gac_context,
    is_gac_safe,
    require_interactive_context,
)

# Policy error exports from 7db.7
from code_puppy.plugins.git_auto_commit.policy_errors import (
    DENIAL_SUGGESTIONS,
    GACPolicyError,
    classify_policy_denial,
    handle_blocked_result,
)

# Shell bridge exports from 7db.6
from code_puppy.plugins.git_auto_commit.shell_bridge import (
    execute_git_command,
    execute_git_command_sync,
)

__version__ = "0.2.0"
__all__ = [
    # Context guard exports
    "GACContextError",
    "REASON_SUBAGENT",
    "REASON_NON_INTERACTIVE",
    "REASON_NESTED_AGENT",
    "check_gac_context",
    "is_gac_safe",
    "require_interactive_context",
    # Shell bridge exports
    "execute_git_command",
    "execute_git_command_sync",
    # Commit flow exports
    "CommitFlowError",
    "preflight_check",
    "generate_preview",
    "execute_commit",
    "run_full_flow",
    # Policy error exports
    "GACPolicyError",
    "classify_policy_denial",
    "handle_blocked_result",
    "DENIAL_SUGGESTIONS",
]
