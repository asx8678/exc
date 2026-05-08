"""Full commit flow: preflight → preview → execute through security boundary.

This module orchestrates the complete git commit workflow:
1. Preflight — Check git status, detect staged/unstaged changes
2. Preview — Generate commit message preview, show what will be committed
3. Execute — Run git commit through security boundary

Each phase calls check_gac_context() FIRST — safety before everything.
"""

import re
import shlex
from typing import Any

from code_puppy.plugins.git_auto_commit.context_guard import (
    check_gac_context,
)
from code_puppy.plugins.git_auto_commit.shell_bridge import execute_git_command_sync

__all__ = [
    "CommitFlowError",
    "preflight_check",
    "generate_preview",
    "execute_commit",
]


class CommitFlowError(Exception):
    """Raised when the commit flow cannot proceed.

    Attributes:
        message: Human-readable error description
        phase: The phase that failed ("preflight", "preview", "execute")
        details: Additional error details (stderr, git output, etc.)
    """

    def __init__(self, message: str, phase: str, details: str | None = None):
        super().__init__(message)
        self.phase = phase
        self.details = details


def preflight_check(cwd: str | None = None) -> dict[str, Any]:
    """Run preflight checks before committing.

    This function:
    1. Checks context safety FIRST (raises GACContextError if unsafe)
    2. Runs git status --porcelain to detect staged/unstaged changes
    3. Parses output to categorize files

    Args:
        cwd: Optional working directory for git commands

    Returns:
        Dict with keys:
            - staged_files: list of staged file paths
            - unstaged_files: list of modified but unstaged files
            - untracked_files: list of untracked files
            - has_staged: bool - whether there are staged changes
            - clean: bool - whether working tree is clean

    Raises:
        GACContextError: If context guard check fails
        CommitFlowError: If git status command fails

    Example:
        >>> result = preflight_check()
        >>> if not result["has_staged"]:
        ...     print("Nothing to commit - stage changes first")
        >>> print(f"Staged: {len(result['staged_files'])} files")
    """
    # 1. Check context safety FIRST
    check_gac_context()

    # 2. Check git status
    result = execute_git_command_sync("git status --porcelain", cwd)
    if not result["success"]:
        raise CommitFlowError(
            f"Preflight failed: {result['error']}",
            phase="preflight",
            details=result.get("reason"),
        )

    # 3. Parse staged vs unstaged vs untracked
    lines = result["output"].strip().split("\n") if result["output"].strip() else []

    staged = []
    unstaged = []
    untracked = []

    for line in lines:
        if not line:
            continue

        status_code = line[:2]
        filename = line[3:]

        # XY format where X = index (staged), Y = working tree (unstaged)
        # X codes: M=modified, A=added, D=deleted, R=renamed, C=copied, U=updated but unmerged
        # ?? = untracked
        # !! = ignored

        if status_code == "??":
            untracked.append(filename)
        elif status_code == "!!":
            # Ignored files - skip
            continue
        else:
            x, y = status_code[0], status_code[1] if len(status_code) > 1 else " "

            # Staged changes (index side)
            if x in ("M", "A", "D", "R", "C", "U"):
                staged.append(filename)

            # Unstaged changes (working tree side)
            if y in ("M", "D", "U"):
                unstaged.append(filename)

    return {
        "staged_files": staged,
        "unstaged_files": unstaged,
        "untracked_files": untracked,
        "has_staged": len(staged) > 0,
        "clean": len(lines) == 0,
    }


def generate_preview(cwd: str | None = None) -> dict[str, Any]:
    """Generate a preview of what would be committed.

    This function:
    1. Checks context safety FIRST
    2. Gets staged diff statistics
    3. Optionally gets full diff (truncated for large outputs)

    Args:
        cwd: Optional working directory for git commands

    Returns:
        Dict with keys:
            - diff: the staged diff stat output
            - file_count: number of files to commit
            - insertions: estimated number of insertions
            - deletions: estimated number of deletions
            - summary: human-readable summary

    Raises:
        GACContextError: If context guard check fails
        CommitFlowError: If git diff command fails

    Example:
        >>> preview = generate_preview()
        >>> print(preview["summary"])  # "3 files changed, 42 insertions(+), 5 deletions(-)"
    """
    check_gac_context()

    # Get staged diff stats
    diff_result = execute_git_command_sync("git diff --cached --stat", cwd)
    if not diff_result["success"]:
        raise CommitFlowError(
            f"Preview failed: {diff_result['error']}",
            phase="preview",
            details=diff_result.get("reason"),
        )

    output = diff_result["output"].strip()

    # Parse stats
    file_count = 0
    insertions = 0
    deletions = 0

    if output:
        lines = output.split("\n")
        for line in lines:
            # Match: " filename | 123 +++"
            # Or: " filename | 45 ---"
            # Or: " filename | 12 +++---"
            match = re.search(r"\|\s+(\d+)\s+([\+\-]*)", line)
            if match:
                file_count += 1
                plus_count = line.count("+")
                minus_count = line.count("-")
                # These are approximate since each + or - represents a line change
                insertions += plus_count
                deletions += minus_count

    # Try to get the summary line (last line usually contains summary)
    summary = f"{file_count} file(s) staged for commit"
    if output:
        lines = output.split("\n")
        for line in reversed(lines):
            if "file" in line.lower() and "changed" in line.lower():
                summary = line.strip()
                break

    return {
        "diff": output,
        "file_count": file_count,
        "insertions": insertions,
        "deletions": deletions,
        "summary": summary,
    }


def execute_commit(message: str, cwd: str | None = None) -> dict[str, Any]:
    """Execute the git commit through security boundary.

    This function:
    1. Checks context safety FIRST
    2. Validates commit message (non-empty)
    3. Sanitizes message for shell safety
    4. Executes git commit
    5. Parses commit hash from output

    Args:
        message: The commit message (will be sanitized for shell safety)
        cwd: Optional working directory for git commands

    Returns:
        Dict with keys:
            - success: bool
            - output: commit output
            - commit_hash: short hash of new commit (if successful, None otherwise)
            - branch: current branch name (if detectable, None otherwise)

    Raises:
        GACContextError: If context guard check fails
        CommitFlowError: If message is empty or commit fails

    Example:
        >>> result = execute_commit("feat: add new feature")
        >>> if result["success"]:
        ...     print(f"Created commit {result['commit_hash']}")
    """
    check_gac_context()

    if not message or not message.strip():
        raise CommitFlowError("Commit message cannot be empty", phase="execute")

    # Sanitize message for shell (prevent injection) using shlex.quote
    safe_message = shlex.quote(message)

    result = execute_git_command_sync(f"git commit -m {safe_message}", cwd)
    if not result["success"]:
        raise CommitFlowError(
            f"Commit failed: {result['error']}",
            phase="execute",
            details=result.get("reason"),
        )

    # Extract commit hash from output
    # Git output format: [branch hash] message
    # e.g., [feature/code_puppy-7db.3 abc1234] feat: add new feature
    commit_hash = None
    branch = None

    output = result.get("output", "")
    for line in output.split("\n"):
        if "[" in line and "]" in line:
            # Parse "[branch hash]" format
            try:
                bracket_content = line.split("[")[1].split("]")[0]
                parts = bracket_content.split()
                if len(parts) >= 2:
                    # Last part before ] is usually the hash
                    commit_hash = parts[-1]
                    # Earlier parts form the branch name
                    branch = " ".join(parts[:-1])
            except IndexError, ValueError:
                pass

    return {
        "success": True,
        "output": output,
        "commit_hash": commit_hash,
        "branch": branch,
    }


def run_full_flow(
    message: str | None = None,
    cwd: str | None = None,
    auto_confirm: bool = False,
) -> dict[str, Any]:
    """Run the full commit flow: preflight → preview → (confirm) → execute.

    This is a convenience function that orchestrates the complete flow.

    Args:
        message: Optional commit message (if None, will generate one or prompt)
        cwd: Optional working directory for git commands
        auto_confirm: If True, skip confirmation (use with caution!)

    Returns:
        Dict with keys:
            - success: bool - whether the full flow succeeded
            - phase: which phase completed/"failed"
            - preflight: preflight results (if reached)
            - preview: preview results (if reached)
            - commit: commit results (if reached)
            - error: error message (if failed)

    Raises:
        GACContextError: If context guard check fails in any phase
        CommitFlowError: If any phase fails

    Example:
        >>> result = run_full_flow("feat: add awesome feature")
        >>> if result["success"]:
        ...     print(f"✓ Committed {result['commit']['commit_hash']}")
    """
    # Phase 1: Preflight
    preflight = preflight_check(cwd)

    if not preflight["has_staged"]:
        return {
            "success": False,
            "phase": "preflight",
            "preflight": preflight,
            "error": "No staged changes to commit. Run 'git add' first.",
        }

    # Phase 2: Preview
    preview = generate_preview(cwd)

    # If no message provided and not auto-confirm, we can't proceed automatically
    if not message and not auto_confirm:
        return {
            "success": False,
            "phase": "preview",
            "preflight": preflight,
            "preview": preview,
            "error": "No commit message provided. Use -m flag or auto_confirm=True.",
        }

    # Phase 3: Execute
    commit_msg = message or f"feat: update {preview['file_count']} files"
    commit = execute_commit(commit_msg, cwd)

    return {
        "success": True,
        "phase": "execute",
        "preflight": preflight,
        "preview": preview,
        "commit": commit,
    }
