"""Shell pass-through for direct command execution.

Prepend a prompt with `!` to execute it as a shell command directly,
bypassing the agent entirely. Inspired by Claude Code's `!` prefix.

Security model:
- This path is for **explicit user-initiated direct shell execution**.
- It does **not** go through the agent/tool safety pipeline used by
  ``agent_run_shell_command``.
- It should be treated like typing a command directly into your terminal.

Examples:
    !ls -la
    !git status
    !python --version
"""

import os
import re
import shlex
import subprocess
import sys
import time

from rich.console import Console
from rich.markup import escape as escape_rich_markup

from code_puppy.config import get_banner_color

# SECURITY FIX fv7t: Add validation to shell passthrough
# These patterns detect dangerous shell constructs that could lead to
# arbitrary code execution. This is defense-in-depth for user-initiated
# direct shell commands (bypassing the agent/tool pipeline).
# NOTE: `shell=True` is required for pipes/redirects/chains. Upstream
# validation assumes the user typed this directly (like a terminal).
DANGEROUS_PATTERNS = [
    # Destructive filesystem operations
    r"rm\s+-rf\s+/",
    r"rm\s+-rf\s+~",
    r">\s*/etc/",
    # Remote code execution via curl/wget piped to shell
    r"curl\s+[^|]*\|\s*(ba)?sh",
    r"wget\s+[^|]*\|\s*(ba)?sh",
    r"curl\s+[^|]*\|\s*bash\s+-[ci]",
    # Eval-based arbitrary execution
    r"\beval(?![\w])\s*['\"$`]",
    r"\beval(?![\w])\s*\(",
    # Backtick command substitution: `rm -rf /`
    r"`[^`]+`",
    # $(...) command substitution: $(rm -rf /)
    r"\$\s*\([^)]+\)",
    # ${...} variable expansion that executes
    r"\$\{[^}]*\bexpr\b",
]
# Using tuple instead of list for memory efficiency and immutability
_COMPILED_DANGEROUS = tuple(re.compile(p, re.IGNORECASE) for p in DANGEROUS_PATTERNS)
MAX_COMMAND_LENGTH = 8192


def _validate_passthrough_command(command: str) -> tuple[bool, str]:
    """Validate command for dangerous patterns.

    Defense-in-depth: User-initiated passthrough commands bypass the
    agent/tool security pipeline. We perform basic sanity checks here.

    Returns:
        Tuple of (is_safe, rejection_reason). is_safe=True means the
        command passed all checks (not that it's "safe", just that
        no obvious dangerous patterns were detected).
    """
    if not command or not command.strip():
        return False, "Empty command"
    if len(command) > MAX_COMMAND_LENGTH:
        return False, "Command too long"
    for pattern in _COMPILED_DANGEROUS:
        if pattern.search(command):
            return False, "Dangerous pattern detected"
    # Additional layer: verify command can be properly parsed by shlex
    # NOTE: shlex validates the command can be tokenized (catches malformed
    # quoting like unbalanced quotes). It does NOT validate shell semantics
    # or prevent injection - "echo hi; rm -rf /" parses fine through shlex.
    try:
        tokens = shlex.split(command, posix=True)
        if not tokens or not any(token.strip() for token in tokens):
            return False, "Command contains no valid tokens"
    except ValueError:
        return False, "Command parsing failed (possible malformed input)"
    return True, ""


# The prefix character that triggers shell pass-through
SHELL_PASSTHROUGH_PREFIX = "!"

# Banner identifier — matches the key in DEFAULT_BANNER_COLORS
_BANNER_NAME = "shell_passthrough"


def _get_console() -> Console:
    """Get a Rich console for direct output.

    Separated for testability — tests can mock this to capture output.
    """
    return Console()


def _format_banner() -> str:
    """Format the SHELL PASSTHROUGH banner using the configured color.

    Uses the same `[bold white on {color}]` pattern as rich_renderer.py
    so the banner looks consistent with SHELL COMMAND, EDIT FILE, etc.

    Returns:
        Rich markup string for the banner.
    """
    color = get_banner_color(_BANNER_NAME)
    return f"[bold white on {color}] 🐚 SHELL PASSTHROUGH [/bold white on {color}]"


def is_shell_passthrough(task: str) -> bool:
    """Check if user input is a shell pass-through command.

    A pass-through command starts with `!` followed by a non-empty command.
    A bare `!` with nothing after it is NOT a pass-through.

    Args:
        task: Raw user input string.

    Returns:
        True if the input is a shell pass-through command.
    """
    stripped = task.strip()
    return (
        stripped.startswith(SHELL_PASSTHROUGH_PREFIX)
        and len(stripped) > len(SHELL_PASSTHROUGH_PREFIX)
        and not stripped[len(SHELL_PASSTHROUGH_PREFIX) :].isspace()
    )


def extract_command(task: str) -> str:
    """Extract the shell command from a pass-through input.

    Strips the leading `!` prefix and any surrounding whitespace.

    Args:
        task: Raw user input (must pass `is_shell_passthrough` check).

    Returns:
        The shell command to execute.
    """
    return task.strip()[len(SHELL_PASSTHROUGH_PREFIX) :].strip()


def execute_shell_passthrough(task: str) -> None:
    """Execute a shell command directly, bypassing the agent.

    Renders a colored banner (matching the codebase banner system) so the
    user instantly sees they're in pass-through mode, then inherits stdio
    for raw terminal output.

    Ctrl+C during execution kills the subprocess, not Code Puppy.

    Args:
        task: Raw user input starting with `!`.
    """
    console = _get_console()
    command = extract_command(task)

    if not command:
        console.print(
            "[yellow]Empty command. Usage: !<command> (e.g., !ls -la)[/yellow]"
        )
        return

    # Escape command to prevent Rich markup injection
    safe_command = escape_rich_markup(command)

    # Banner + command on one line, context hint below
    banner = _format_banner()
    console.print(f"\n{banner} [dim]$ {safe_command}[/dim]")
    console.print("[dim]↳ Direct shell · Minimal safety checks applied[/dim]")

    start_time = time.monotonic()

    # SECURITY FIX fv7t: Validate before execution (multiple defense layers)
    is_safe, rejection_reason = _validate_passthrough_command(command)
    if not is_safe:
        console.print(f"[bold red]🛡️ Command blocked:[/bold red] {rejection_reason}")
        console.print("[dim]Use agent tools or /yolo mode for this operation.[/dim]")
        return

    # SECURITY: shell=True is REQUIRED for pipes/redirects/command chains
    # (e.g., "!cat file | grep pattern"). This is user-initiated direct shell
    # execution—treat it like the user typed it in their terminal. The command
    # has passed _validate_passthrough_command() which validates:
    # - Length limits, no empty commands
    # - No dangerous patterns (backticks, command substitution, etc.)
    # - Proper shlex tokenization (validates quoting only, NOT injection)
    # User confirms intent by prefixing with "!". For stricter control,
    # users should invoke tools via the agent instead.
    try:
        # nosec B602 - required for shell features (user escape hatch with
        # documented raw-shell semantics); risk managed by explicit user invocation
        result = subprocess.run(
            command,
            shell=True,  # nosec B602 - shell features required, validated above
            cwd=os.getcwd(),
            # Inherit stdio — output goes straight to the terminal
            stdin=sys.stdin,
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
        elapsed = time.monotonic() - start_time

        if result.returncode == 0:
            console.print(
                f"[bold green]✅ Done[/bold green] [dim]({elapsed:.1f}s)[/dim]"
            )
        else:
            console.print(
                f"[bold red]❌ Exit code {result.returncode}[/bold red] "
                f"[dim]({elapsed:.1f}s)[/dim]"
            )

    except KeyboardInterrupt:
        elapsed = time.monotonic() - start_time
        console.print(
            f"\n[bold yellow]⚡ Interrupted[/bold yellow] [dim]({elapsed:.1f}s)[/dim]"
        )

    except Exception as e:
        safe_error = escape_rich_markup(str(e))
        console.print(f"[bold red]Shell error:[/bold red] {safe_error}")
