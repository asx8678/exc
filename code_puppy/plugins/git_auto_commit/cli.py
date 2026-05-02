"""Standalone CLI entry point for gac (git auto commit).

Usage:
    gac                    # Show status, stage all, commit with generated message, push
    gac -m "message"       # Commit with specific message
    gac --no-push          # Commit only, don't push
    gac --dry-run          # Preview only, don't execute
"""

import argparse
import sys

from code_puppy.plugins.git_auto_commit.commit_flow import (
    CommitFlowError,
    execute_commit,
    generate_preview,
    preflight_check,
)
from code_puppy.plugins.git_auto_commit.context_guard import is_gac_safe
from code_puppy.plugins.git_auto_commit.shell_bridge import execute_git_command_sync


def _stage_all() -> bool:
    """Stage all changes (including untracked)."""
    result = execute_git_command_sync("git add -A")
    return result["success"]


def _push(branch: str | None = None) -> dict:
    """Push to remote."""
    cmd = f"git push origin {branch}" if branch else "git push"
    return execute_git_command_sync(cmd)


def _get_current_branch() -> str | None:
    """Get current git branch."""
    result = execute_git_command_sync("git branch --show-current")
    if result["success"]:
        return result["output"].strip()
    return None


def _generate_commit_message(preflight: dict) -> str:
    """Generate a simple commit message based on changes."""
    staged = preflight.get("staged_files", [])
    file_count = len(staged)

    # Simple heuristic for message type
    has_tests = any("test" in f.lower() for f in staged)
    has_docs = any(f.endswith(".md") for f in staged)
    has_fix = any(f.startswith("fix") or "fix" in f.lower() for f in staged)

    if has_fix:
        prefix = "fix"
    elif has_tests:
        prefix = "test"
    elif has_docs:
        prefix = "docs"
    elif file_count == 1:
        prefix = "feat"
    else:
        prefix = "chore"

    if file_count == 1:
        return f"{prefix}: update {staged[0]}"
    else:
        return f"{prefix}: update {file_count} files"


def main() -> int:
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        prog="gac",
        description="Git Auto Commit - stage, commit, and push in one command",
    )
    parser.add_argument(
        "-m",
        "--message",
        help="Commit message (auto-generated if not provided)",
    )
    parser.add_argument(
        "--no-push",
        action="store_true",
        help="Commit only, don't push",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview only, don't execute",
    )
    parser.add_argument(
        "--no-stage",
        action="store_true",
        help="Don't auto-stage changes (use only if already staged)",
    )

    args = parser.parse_args()

    # Check GAC context (warn but don't block in CLI mode)
    is_safe, reason = is_gac_safe()
    if not is_safe:
        print(f"⚠️  Context warning: {reason}")
        print("   Proceeding anyway in CLI mode...\n")

    # Preflight check
    print("🔍 Checking git status...")
    try:
        preflight = preflight_check()
    except Exception as e:
        print(f"❌ Preflight failed: {e}")
        return 1

    if preflight["clean"]:
        print("📭 Working tree clean - nothing to commit")
        return 0

    # Stage changes if needed
    if not args.no_stage and not preflight["has_staged"]:
        print("📦 Staging all changes...")
        if not _stage_all():
            print("❌ Failed to stage changes")
            return 1
        # Re-check after staging
        preflight = preflight_check()

    if not preflight["has_staged"]:
        print("❌ No staged changes to commit")
        return 1

    staged_count = len(preflight["staged_files"])
    print(f"✅ {staged_count} file(s) ready to commit")

    # Generate preview
    try:
        preview = generate_preview()
        print(f"\n📋 {preview['summary']}")
    except Exception as e:
        print(f"⚠️  Could not generate preview: {e}")

    # Dry run mode
    if args.dry_run:
        print("\n🏃 Dry run - not executing")
        return 0

    # Generate or use provided message
    message = args.message
    if not message:
        message = _generate_commit_message(preflight)
        print(f"\n📝 Auto-generated message: '{message}'")

    # Commit
    print("\n💾 Committing...")
    try:
        commit_result = execute_commit(message)
        commit_hash = commit_result.get("commit_hash", "?")
        print(f"✓ Committed: {commit_hash}")
    except CommitFlowError as e:
        print(f"❌ Commit failed: {e}")
        return 1
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return 1

    # Push
    if not args.no_push:
        branch = _get_current_branch()
        branch_str = f" ({branch})" if branch else ""
        print(f"\n🚀 Pushing{branch_str}...")
        push_result = _push(branch)
        if push_result["success"]:
            print("✓ Pushed to remote")
        else:
            error = push_result.get("error", "Unknown error")
            print(f"❌ Push failed: {error}")
            return 1

    print("\n🎉 Done!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
