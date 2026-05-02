"""Clean error handling for policy-blocked git commands.

When project-level policy rules or hooks block git commands, GAC must
surface those denials with actionable messages that help users understand
WHY a command was blocked and WHAT they can do about it.
"""


class GACPolicyError(Exception):
    """Raised when a git command is blocked by policy."""

    def __init__(
        self,
        command: str,
        reason: str,
        policy_source: str | None = None,
        suggestion: str | None = None,
    ):
        self.command = command
        self.reason = reason
        self.policy_source = policy_source
        self.suggestion = suggestion
        super().__init__(self.user_message)

    @property
    def user_message(self) -> str:
        """Format a clean, actionable error message."""
        parts = [f"GAC blocked: `{self.command}` was denied by policy."]
        parts.append(f"Reason: {self.reason}")
        if self.policy_source:
            parts.append(f"Policy source: {self.policy_source}")
        if self.suggestion:
            parts.append(f"To resolve: {self.suggestion}")
        return "\n".join(parts)


# Map common denial patterns to actionable suggestions
DENIAL_SUGGESTIONS: dict[str, str] = {
    "git push": "GAC v1 does not support push. Commit locally and push manually.",
    "git reset": "Reset operations are not permitted through GAC for safety.",
    "git checkout": "Branch operations should be done manually, not through GAC.",
    "git rebase": "Rebase operations are not permitted through GAC for safety.",
    "destructive": "This command was classified as destructive. Review your project's .code_puppy/policy.json.",
    "not_in_allowlist": "This git subcommand is not in GAC's allowed list. Check register_callbacks.py for supported commands.",
}


def classify_policy_denial(
    command: str,
    raw_reason: str,
    raw_source: str | None = None,
) -> GACPolicyError:
    """Classify a raw policy denial into a clean, actionable error.

    Takes the raw reason string from SecurityBoundary and maps it to
    a user-friendly GACPolicyError with suggestions.
    """
    # Determine suggestion based on command and reason
    # Priority: reason patterns (explain WHY) before command patterns (explain WHAT)
    suggestion = None

    # First check reason patterns - they provide context on WHY it was blocked
    for pattern, sugg in DENIAL_SUGGESTIONS.items():
        if pattern in raw_reason.lower():
            suggestion = sugg
            break

    # Then check command patterns if no reason match
    if suggestion is None:
        for pattern, sugg in DENIAL_SUGGESTIONS.items():
            if pattern in command.lower():
                suggestion = sugg
                break

    # Default suggestion if no pattern matched
    if suggestion is None:
        suggestion = (
            "Check your project policy at .code_puppy/policy.json "
            "or user policy at ~/.code_puppy/policy.json. "
            "You can also run the command manually in your terminal."
        )

    # Clean up the policy source
    policy_source = _clean_policy_source(raw_source)

    return GACPolicyError(
        command=command,
        reason=raw_reason,
        policy_source=policy_source,
        suggestion=suggestion,
    )


def handle_blocked_result(command: str, result: dict) -> GACPolicyError | None:
    """Check a shell_bridge result dict and return a GACPolicyError if blocked.

    Returns None if the result is not blocked.
    """
    if not result.get("blocked"):
        return None

    return classify_policy_denial(
        command=command,
        raw_reason=result.get("reason", "Unknown policy denial"),
        raw_source=result.get("policy_source"),
    )


def _clean_policy_source(source: str | None) -> str | None:
    """Clean up policy source string for user display."""
    if not source:
        return None
    # Map internal source names to user-friendly names
    source_map = {
        "policy_engine": "Project policy rules (.code_puppy/policy.json)",
        "user_policy": "User policy (~/.code_puppy/policy.json)",
        "shell_safety": "Shell safety analysis (automatic)",
        "run_shell_command": "Shell command callback",
    }
    return source_map.get(source, source)
