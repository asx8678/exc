"""Command handlers for REPL session management (/repl command).

This module provides commands for managing persistent REPL sessions:
- /repl - Show current REPL session info
- /repl reset - Reset session state
- /repl import <autosave_id> - Import from autosave
- /repl context - Show loaded context
- /repl context clear - Clear loaded files
"""

from code_puppy.command_line.command_registry import register_command
from code_puppy.messaging import emit_info, emit_success, emit_warning
from code_puppy.repl_session import (
    clear_loaded_files,
    get_command_history,
    get_current_session,
    import_session_from_autosave,
    reset_session,
    save_session,
)


@register_command(
    name="repl",
    description="Show or manage REPL session state",
    usage="/repl [reset|import <id>|context|history]",
    category="session",
)
def handle_repl_command(command: str) -> bool:
    """Handle the /repl command for REPL session management."""
    tokens = command.split()

    # If no subcommand, show current session info
    if len(tokens) == 1:
        _show_repl_info()
        return True

    subcommand = tokens[1].lower()

    if subcommand == "reset":
        reset_session()
        emit_success("REPL session reset. All context cleared.")
        return True

    if subcommand == "import":
        if len(tokens) < 3:
            emit_warning("Usage: /repl import <autosave_id>")
            return True
        autosave_id = tokens[2]
        import_session_from_autosave(autosave_id)
        return True

    if subcommand == "context":
        if len(tokens) > 2 and tokens[2].lower() == "clear":
            clear_loaded_files()
            emit_success("Loaded context cleared")
            return True
        _show_context()
        return True

    if subcommand == "history":
        limit = 20
        if len(tokens) > 2:
            try:
                limit = int(tokens[2])
            except ValueError:
                pass
        _show_history(limit)
        return True

    if subcommand == "save":
        save_session()
        emit_success("REPL session saved")
        return True

    # Invalid usage
    emit_warning("Usage: /repl [reset|import <id>|context|context clear|history|save]")
    return True


def _show_repl_info() -> None:
    """Display current REPL session information."""
    from rich.text import Text

    session = get_current_session()

    # Build status message
    lines: list[str] = []
    lines.append("[bold magenta]REPL Session[/bold magenta]")
    lines.append("")
    lines.append(f"[bold]Session ID:[/bold]    [cyan]{session.session_id}[/cyan]")
    lines.append(f"[bold]Working Dir:[/bold]    [dim]{session.working_directory}[/dim]")
    lines.append(f"[bold]Commands:[/bold]      [cyan]{session.command_count}[/cyan]")
    lines.append(f"[bold]Messages:[/bold]      [cyan]{session.message_count}[/cyan]")
    lines.append("")
    lines.append("[bold]Configuration:[/bold]")
    lines.append(f"  Agent:    [cyan]{session.current_agent}[/cyan]")
    lines.append(f"  Model:    [cyan]{session.current_model or 'default'}[/cyan]")
    lines.append(f"  Mode:     [cyan]{session.current_mode}[/cyan]")
    lines.append(f"  Pack:     [cyan]{session.current_pack}[/cyan]")

    if session.loaded_files:
        lines.append("")
        lines.append(
            f"[bold]Loaded Files:[/bold] [cyan]{len(session.loaded_files)}[/cyan] (use /repl context)"
        )

    if session.autosave_session_id:
        lines.append("")
        lines.append(
            f"[bold]Linked Autosave:[/bold] [cyan]{session.autosave_session_id}[/cyan]"
        )

    lines.append("")
    lines.append("[dim]Use /repl reset to start fresh[/dim]")
    lines.append("[dim]Use /repl context to view loaded files[/dim]")
    lines.append("[dim]Use /repl history to see command history[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))


def _show_context() -> None:
    """Display loaded context files."""
    from rich.text import Text

    session = get_current_session()

    lines: list[str] = []
    lines.append("[bold magenta]REPL Context[/bold magenta]")
    lines.append("")

    if session.loaded_files:
        lines.append(
            f"[bold]Loaded Files:[/bold] [cyan]{len(session.loaded_files)}[/cyan]"
        )
        lines.append("")
        for i, file_path in enumerate(session.loaded_files, 1):
            # Truncate long paths
            display_path = file_path
            if len(display_path) > 60:
                display_path = "..." + display_path[-57:]
            lines.append(f"  {i}. [dim]{display_path}[/dim]")
    else:
        lines.append("[dim]No files loaded in context[/dim]")

    lines.append("")
    lines.append("[dim]Use /repl context clear to clear all files[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))


def _show_history(limit: int = 20) -> None:
    """Display command history."""
    from datetime import datetime

    from rich.text import Text

    history = get_command_history(limit)

    lines: list[str] = []
    lines.append(
        f"[bold magenta]Command History[/bold magenta] (last {len(history)} commands)"
    )
    lines.append("")

    if history:
        for entry in history:
            timestamp = entry.get("timestamp", 0)
            cmd = entry.get("command", "")
            time_str = datetime.fromtimestamp(timestamp).strftime("%H:%M:%S")
            # Truncate long commands
            display_cmd = cmd
            if len(display_cmd) > 50:
                display_cmd = display_cmd[:47] + "..."
            lines.append(f"[dim]{time_str}[/dim]  {display_cmd}")
    else:
        lines.append("[dim]No command history yet[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))
