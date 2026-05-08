"""Register callbacks for the Git Auto Commit (GAC) plugin.

This module registers:
- `custom_command` handler for `/commit` slash command
- `custom_command_help` to add entry to `/help` menu

The `/commit` command orchestrates the full commit flow:
- `/commit` (no args) → runs preflight, shows preview
- `/commit status` → runs preflight only
- `/commit preview` → shows what would be committed
- `/commit -m "message"` → runs full flow with given message

All operations go through the security boundary:
1. Context guard ensures safe execution context
2. Shell bridge executes git commands via security boundary
"""

import logging

from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info

from .commit_flow import (
    CommitFlowError,
    execute_commit,
    generate_preview,
    preflight_check,
)
from .context_guard import GACContextError, is_gac_safe
from .policy_errors import handle_blocked_result

logger = logging.getLogger(__name__)


def _commit_help() -> list[tuple[str, str]]:
    """Return help text for the /commit command.

    Returns:
        List of (command_name, description) tuples for the /help menu.
    """
    return [
        (
            "commit",
            "Git auto-commit - preflight → preview → execute through security boundary",
        ),
        ("commit status", "Run preflight check only (git status --porcelain)"),
        ("commit preview", "Show what would be committed (git diff --cached --stat)"),
        ('commit -m "msg"', "Execute commit with message through security boundary"),
    ]


def _parse_commit_args(command: str) -> dict:
    """Parse /commit command arguments.

    Args:
        command: Full command string (e.g., "/commit -m 'message'")

    Returns:
        Dict with parsed arguments:
            - subcommand: 'default', 'status', 'preview', or 'execute'
            - message: commit message if -m flag provided
            - dry_run: True for status/preview subcommands
    """
    parts = command.split()

    # Remove the '/commit' prefix
    if parts and parts[0] in ("/commit", "commit"):
        parts = parts[1:]

    if not parts:
        return {"subcommand": "default", "message": None, "dry_run": False}

    # Check for subcommands
    first = parts[0].lower()
    if first == "status":
        return {"subcommand": "status", "message": None, "dry_run": True}
    if first == "preview":
        return {"subcommand": "preview", "message": None, "dry_run": True}

    # Check for -m flag (execute with message)
    message = None
    i = 0
    while i < len(parts):
        if parts[i] == "-m" and i + 1 < len(parts):
            # Take everything after -m as the message
            message = " ".join(parts[i + 1 :])
            # Remove surrounding quotes if present
            if (message.startswith('"') and message.endswith('"')) or (
                message.startswith("'") and message.endswith("'")
            ):
                message = message[1:-1]
            break
        i += 1

    if message:
        return {"subcommand": "execute", "message": message, "dry_run": False}

    # Unknown args - treat as default
    return {"subcommand": "default", "message": None, "dry_run": False}


def _handle_commit_command(command: str, name: str) -> bool | str | None:
    """Handle the /commit slash command.

    Orchestrates the commit flow through three phases:
    1. Preflight: Check git status, detect staged/unstaged changes
    2. Preview: Generate commit message preview, show what will be committed
    3. Execute: Run git commit through security boundary (if message provided)

    Each phase calls check_gac_context() FIRST — safety before everything.

    Args:
        command: The full command string (e.g., "/commit -m 'feat: add stuff'")
        name: The command name (always "commit" for this handler)

    Returns:
        True if successful, or a descriptive error string if failed
    """
    if name != "commit":
        # Not our command - let other handlers try
        return None  # type: ignore[return-value]

    logger.info(f"GAC: Executing /{command}")
    emit_info("🐕 GAC: Starting commit flow through security boundary...")

    # Check context safety FIRST (before any git operations)
    is_safe, reason = is_gac_safe()
    if not is_safe:
        error_msg = f"🛑 GAC refused: {reason}"
        logger.warning(f"GAC: {error_msg}")
        emit_info(error_msg)
        return error_msg

    # Parse arguments
    args = _parse_commit_args(command)
    subcommand = args["subcommand"]
    message = args["message"]

    try:
        # === PHASE 1: Preflight ===
        emit_info("🔍 Phase 1: Preflight check...")
        preflight = preflight_check()

        if preflight["clean"]:
            emit_info("📭 Working tree is clean - nothing to commit")
            return "Working tree clean - nothing to commit"

        if not preflight["has_staged"]:
            unstaged_count = len(preflight["unstaged_files"])
            untracked_count = len(preflight["untracked_files"])
            emit_info(
                f"⚠️ No staged changes. {unstaged_count} unstaged, {untracked_count} untracked. "
                "Run 'git add' first."
            )
            return f"No staged changes. {unstaged_count} modified, {untracked_count} untracked. Run 'git add' first."

        staged_count = len(preflight["staged_files"])
        emit_info(f"✅ Found {staged_count} staged file(s)")

        # If only status requested, we're done
        if subcommand == "status":
            return True

        # === PHASE 2: Preview ===
        emit_info("📋 Phase 2: Generating preview...")
        preview = generate_preview()

        emit_info(f"   Summary: {preview['summary']}")
        if preview["diff"]:
            lines = preview["diff"].split("\n")[:15]  # Show first 15 lines
            diff_preview = "\n".join(lines)
            if len(preview["diff"].split("\n")) > 15:
                diff_preview += (
                    f"\n... ({len(preview['diff'].split(chr(10))) - 15} more lines)"
                )
            emit_info(f"   Diff:\n{diff_preview}")

        # If only preview requested, we're done
        if subcommand == "preview":
            return True

        # === PHASE 3: Execute (if message provided) ===
        if not message:
            # Default mode without -m flag: show what's ready and ask for confirmation
            emit_info("💡 Use '/commit -m \"your message\"' to execute the commit")
            return True

        emit_info(f'🔒 Phase 3: Executing commit with message: "{message}"')

        result = execute_commit(message)

        if result.get("blocked"):
            # Command was blocked by security - use clean policy error formatting
            policy_error = handle_blocked_result("git commit", result)
            if policy_error:
                error_msg = f"🛑 {policy_error.user_message}"
            else:
                # Fallback if handle_blocked_result returns None
                reason = result.get("reason", "Unknown security reason")
                error_msg = f"🛑 Command blocked by security: {reason}"
            logger.warning(f"GAC: {error_msg}")
            emit_info(error_msg)
            return error_msg

        if result["success"]:
            commit_hash = result.get("commit_hash", "unknown")
            branch = result.get("branch", "unknown")
            emit_info(f"✅ Successfully committed [{commit_hash}] on {branch}")
            logger.info(f"GAC: Committed {commit_hash} on {branch}")
            return True
        else:
            error_msg = f"❌ Commit failed: {result.get('output', 'Unknown error')}"
            logger.error(f"GAC: {error_msg}")
            emit_info(error_msg)
            return error_msg

    except GACContextError as e:
        error_msg = f"🛑 Security check failed: {e}"
        logger.warning(f"GAC: Context error - {e}")
        emit_info(error_msg)
        return error_msg

    except CommitFlowError as e:
        error_msg = f"❌ Commit flow failed in {e.phase} phase: {e}"
        if e.details:
            error_msg += f" (Details: {e.details})"
        logger.error(f"GAC: Flow error - {e}")
        emit_info(error_msg)
        return error_msg

    except Exception as e:
        error_msg = f"💥 Unexpected error: {type(e).__name__}: {e}"
        logger.exception(f"GAC: Unexpected error - {e}")
        emit_info(error_msg)
        return error_msg


# =============================================================================
# Register callbacks
# =============================================================================

register_callback("custom_command_help", _commit_help)
register_callback("custom_command", _handle_commit_command)

logger.debug("Git Auto Commit (GAC) callbacks registered (v0.2.0)")


__all__ = [
    "_commit_help",
    "_handle_commit_command",
    "_parse_commit_args",
]
