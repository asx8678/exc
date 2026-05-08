"""Commands for managing concurrency limits.

Provides commands:
- /concurrency - Show current concurrency status
- /concurrency reload - Reload configuration from disk
- /convergence - Alias for /concurrency
"""

from code_puppy.command_line.command_registry import register_command
from code_puppy.concurrency_limits import (
    ensure_config_file,
    get_concurrency_status,
    reload_concurrency_config,
)
from code_puppy.config_paths import resolve_path
from code_puppy.messaging import emit_info, emit_success, emit_warning


@register_command(
    name="concurrency",
    description="Show or manage concurrency limits",
    usage="/concurrency [reload]",
    category="config",
)
def handle_concurrency_command(command: str) -> bool:
    """Handle /concurrency command."""
    tokens = command.split()

    if len(tokens) == 1:
        _show_concurrency_status()
        return True

    subcommand = tokens[1].lower()

    if subcommand == "reload":
        reload_concurrency_config()
        emit_success("Concurrency configuration reloaded")
        _show_concurrency_status()
        return True

    if subcommand == "config":
        path = ensure_config_file()
        emit_info(f"Configuration file: {path}")
        if path.exists():
            content = path.read_text()
            emit_info(content)
        return True

    emit_warning("Usage: /concurrency [reload|config]")
    return True


@register_command(
    name="convergence",
    description="Alias for /concurrency",
    usage="/convergence [reload]",
    category="config",
)
def handle_convergence_command(command: str) -> bool:
    """Handle /convergence command (alias for /concurrency)."""
    # Remove the alias prefix and pass to main handler
    rest = command[len("/convergence") :].strip()
    return handle_concurrency_command(f"/concurrency {rest}".strip())


def _show_concurrency_status() -> None:
    """Display current concurrency limits and status."""
    from rich.text import Text

    status = get_concurrency_status()

    lines: list[str] = []
    lines.append("[bold magenta]Concurrency Limits[/bold magenta]")
    lines.append("")
    lines.append("[bold]File Operations:[/bold]")
    lines.append(f"  Limit:     [cyan]{status['file_ops_limit']}[/cyan]")
    lines.append(f"  Available: [cyan]{status['file_ops_available']}[/cyan]")
    lines.append("")
    lines.append("[bold]API Calls:[/bold]")
    lines.append(f"  Limit:     [cyan]{status['api_calls_limit']}[/cyan]")
    lines.append(f"  Available: [cyan]{status['api_calls_available']}[/cyan]")
    lines.append("")
    lines.append("[bold]Tool Calls:[/bold]")
    lines.append(f"  Limit:     [cyan]{status['tool_calls_limit']}[/cyan]")
    lines.append(f"  Available: [cyan]{status['tool_calls_available']}[/cyan]")
    lines.append("")

    config_path = resolve_path("concurrency.toml")
    if config_path.exists():
        lines.append(f"[dim]Config: {config_path}[/dim]")
    else:
        lines.append("[dim]Using defaults (no config file)[/dim]")
        lines.append("[dim]Run /concurrency config to see path[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))
