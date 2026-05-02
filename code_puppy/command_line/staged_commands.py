"""Commands for managing staged changes (/staged command).

Provides commands:
- /staged - Show current staged changes summary
- /staged on|off - Enable/disable staging mode
- /staged diff - Show combined diff of all staged changes
- /staged preview - Preview changes by file
- /staged clear - Clear all staged changes
- /staged apply - Apply all staged changes
- /staged reject - Reject all staged changes
"""

from pathlib import Path

from code_puppy.command_line.command_registry import register_command
from code_puppy.messaging import emit_error, emit_info, emit_success, emit_warning
from code_puppy.staged_changes import (
    clear_staged,
    get_sandbox,
)


@register_command(
    name="staged",
    description="Show or manage staged changes for safe edit application",
    usage="/staged [on|off|diff|preview|clear|apply|reject|status]",
    category="edit",
)
def handle_staged_command(command: str) -> bool:
    """Handle the /staged command."""
    tokens = command.split()
    sandbox = get_sandbox()

    # If no subcommand, show summary
    if len(tokens) == 1:
        _show_staged_summary()
        return True

    subcommand = tokens[1].lower()

    if subcommand == "on":
        sandbox.enable()
        emit_success("📝 Staging mode enabled - file edits will be staged for review")
        _show_staged_summary()
        return True

    if subcommand == "off":
        sandbox.disable()
        emit_warning(
            "📝 Staging mode disabled - file edits will be applied immediately"
        )
        return True

    if subcommand in ("status", "summary"):
        _show_staged_summary()
        return True

    if subcommand == "diff":
        _show_combined_diff()
        return True

    if subcommand == "preview":
        _show_preview()
        return True

    if subcommand == "clear":
        count = sandbox.count()
        if count > 0:
            clear_staged()
            emit_success(f"Cleared {count} staged changes")
        else:
            emit_info("No staged changes to clear")
        return True

    if subcommand == "apply":
        _apply_staged_changes()
        return True

    if subcommand == "reject":
        _reject_staged_changes()
        return True

    if subcommand == "save":
        path = sandbox.save_to_disk()
        emit_success(f"Staged changes saved to {path}")
        return True

    if subcommand == "load":
        if sandbox.load_from_disk():
            emit_success("Staged changes loaded from disk")
            _show_staged_summary()
        else:
            emit_error("No saved staged changes found")
        return True

    # Invalid usage
    emit_warning(
        "Usage: /staged [on|off|diff|preview|clear|apply|reject|save|load|status]"
    )
    return True


def _show_staged_summary() -> None:
    """Display summary of staged changes."""
    from rich.text import Text

    sandbox = get_sandbox()
    summary = sandbox.get_summary()

    lines: list[str] = []

    # Header with status
    status = "🟢 ON" if summary["enabled"] else "🔴 OFF"
    lines.append(f"[bold magenta]Staged Changes[/bold magenta] ({status})")
    lines.append("")

    # Summary stats
    total = summary["total"]
    if total == 0:
        lines.append("[dim]No pending staged changes[/dim]")
    else:
        lines.append(f"[bold]{total}[/bold] pending change{'s' if total != 1 else ''}")

        # By type
        by_type = summary.get("by_type", {})
        if by_type:
            lines.append("")
            lines.append("[bold]By type:[/bold]")
            for type_name, count in by_type.items():
                lines.append(f"  {type_name}: [cyan]{count}[/cyan]")

        # Files affected
        files = summary.get("files", [])
        if files:
            lines.append("")
            lines.append(f"[bold]Files affected:[/bold] [cyan]{len(files)}[/cyan]")
            for f in files[:5]:  # Show first 5
                lines.append(f"  [dim]{f}[/dim]")
            if len(files) > 5:
                lines.append(f"  [dim]... and {len(files) - 5} more[/dim]")

    lines.append("")
    lines.append("[dim]Commands:[/dim]")
    lines.append("  [dim]/staged on[/dim]      - Enable staging mode")
    lines.append("  [dim]/staged diff[/dim]    - View combined diff")
    lines.append("  [dim]/staged preview[/dim] - Preview by file")
    lines.append("  [dim]/staged apply[/dim]   - Apply all changes")
    lines.append("  [dim]/staged reject[/dim]  - Reject all changes")
    lines.append("  [dim]/staged clear[/dim]   - Clear staged changes")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))


def _show_combined_diff() -> None:
    """Display combined diff of all staged changes."""
    from rich.syntax import Syntax
    from rich.text import Text

    sandbox = get_sandbox()
    diff = sandbox.generate_combined_diff()

    if not diff:
        emit_info("No staged changes to diff")
        return

    emit_info("[bold magenta]Combined Diff of Staged Changes:[/bold magenta]\n")

    # Output diff with syntax highlighting
    try:
        from code_puppy.tools.common import console

        console.print(Syntax(diff, "diff", theme="monokai", line_numbers=False))
    except Exception:
        # Fallback to plain text
        emit_info(Text.from_markup(f"```diff\n{diff}\n```"))


def _show_preview() -> None:
    """Display preview of changes grouped by file."""
    sandbox = get_sandbox()
    preview = sandbox.preview_changes()

    if not preview:
        emit_info("No staged changes to preview")
        return

    lines: list[str] = []
    lines.append("[bold magenta]Preview of Staged Changes by File:[/bold magenta]")
    lines.append("")

    for file_path, diff in preview.items():
        lines.append(f"[bold cyan]{file_path}[/bold cyan]")
        if diff:
            lines.append("```diff")
            lines.append(diff)
            lines.append("```")
        else:
            lines.append("[dim]No diff available[/dim]")
        lines.append("")

    status_msg = "\n".join(lines)
    emit_info(status_msg)


def _apply_staged_changes() -> None:
    """Apply all staged changes to files."""
    sandbox = get_sandbox()
    changes = sandbox.get_staged_changes()

    if not changes:
        emit_info("No staged changes to apply")
        return

    # Apply each change
    applied_count = 0
    failed_count = 0

    for change in changes:
        try:
            if _apply_single_change(change):
                change.applied = True
                applied_count += 1
            else:
                failed_count += 1
        except Exception as e:
            emit_error(f"Failed to apply change {change.change_id}: {e}")
            failed_count += 1

    # Save state after applying
    sandbox.save_to_disk()

    if failed_count == 0:
        emit_success(f"✅ Applied {applied_count} staged changes successfully")
    else:
        emit_warning(f"Applied {applied_count} changes, {failed_count} failed")

    # Clear applied changes
    sandbox.clear()


def _apply_single_change(change) -> bool:
    """Apply a single staged change."""
    from code_puppy.staged_changes import ChangeType

    try:
        if change.change_type == ChangeType.CREATE:
            return _apply_create(change)
        elif change.change_type == ChangeType.REPLACE:
            return _apply_replace(change)
        elif change.change_type == ChangeType.DELETE_SNIPPET:
            return _apply_delete_snippet(change)
        return False
    except Exception as e:
        emit_error(f"Error applying change: {e}")
        return False


def _apply_create(change) -> bool:
    """Apply a file creation change."""
    file_path = change.file_path
    content = change.content or ""

    # Ensure directory exists
    Path(file_path).parent.mkdir(parents=True, exist_ok=True)

    # Write file
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)

    emit_success(f"Created: {file_path}")
    return True


def _apply_replace(change) -> bool:
    """Apply a text replacement change."""
    file_path = change.file_path
    old_str = change.old_str or ""
    new_str = change.new_str or ""

    if not Path(file_path).exists():
        emit_error(f"File not found: {file_path}")
        return False

    with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        content = f.read()

    if old_str not in content:
        emit_warning(f"Old string not found in {file_path}")
        return False

    new_content = content.replace(old_str, new_str, 1)

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    emit_success(f"Modified: {file_path}")
    return True


def _apply_delete_snippet(change) -> bool:
    """Apply a snippet deletion change."""
    file_path = change.file_path
    snippet = change.snippet or ""

    if not Path(file_path).exists():
        emit_error(f"File not found: {file_path}")
        return False

    with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        content = f.read()

    if snippet not in content:
        emit_warning(f"Snippet not found in {file_path}")
        return False

    new_content = content.replace(snippet, "", 1)

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    emit_success(f"Modified: {file_path}")
    return True


def _reject_staged_changes() -> None:
    """Reject (clear) all staged changes without applying."""
    sandbox = get_sandbox()
    count = sandbox.count()

    if count == 0:
        emit_info("No staged changes to reject")
        return

    # Mark all as rejected
    for change in sandbox.get_staged_changes():
        change.rejected = True

    sandbox.save_to_disk()
    sandbox.clear()

    emit_success(f"❌ Rejected {count} staged changes")
