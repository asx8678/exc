"""Command handlers for configuration presets (/mode command).

This module provides the /mode command for viewing and switching between
configuration presets (basic, semi, full, pack).
"""

from code_puppy.command_line.command_registry import register_command
from code_puppy.config_presets import (
    apply_preset,
    get_current_preset_guess,
    get_preset,
    list_presets,
)
from code_puppy.messaging import emit_info, emit_success, emit_warning


@register_command(
    name="mode",
    description="Show or switch configuration preset (basic/semi/full/pack)",
    usage="/mode [preset_name]",
    category="config",
)
def handle_mode_command(command: str) -> bool:
    """Handle the /mode command for switching presets."""
    tokens = command.split()

    # If no preset specified, show current mode and available presets
    if len(tokens) == 1:
        _show_current_mode()
        return True

    # Apply the specified preset
    if len(tokens) == 2:
        preset_name = tokens[1].lower()

        if apply_preset(preset_name, emit=True):
            # Reload agent if needed
            try:
                from code_puppy.agents.agent_manager import get_current_agent

                agent = get_current_agent()
                agent.reload_code_generation_agent()
                emit_success("Agent reloaded with new configuration")
            except Exception:
                pass  # Agent reload is best effort
        return True

    # Invalid usage
    emit_warning("Usage: /mode [basic|semi|full|pack]")
    emit_info("Use /mode without arguments to see current mode")
    return True


def _show_current_mode() -> None:
    """Display current mode and available presets."""
    from rich.text import Text

    current_preset = get_current_preset_guess()
    presets = list_presets()

    # Build status message
    lines: list[str] = []
    lines.append("[bold magenta]Configuration Mode[/bold magenta]")
    lines.append("")

    if current_preset:
        preset = get_preset(current_preset)
        lines.append(f"[bold]Current mode:[/bold] [cyan]{preset.display_name}[/cyan]")
        lines.append(f"[dim]{preset.description}[/dim]")
    else:
        lines.append("[bold]Current mode:[/bold] [yellow]Custom[/yellow]")
        lines.append("[dim]Your configuration doesn't match any preset.[/dim]")

    lines.append("")
    lines.append("[bold]Available presets:[/bold]")

    for preset in presets:
        marker = "→ " if preset.name == current_preset else "  "
        lines.append(
            f"{marker}[cyan]/{preset.name:<10}[/cyan] [dim]{preset.description}[/dim]"
        )

    lines.append("")
    lines.append("[dim]Use /mode <preset> to switch modes[/dim]")
    lines.append("[dim]Use /show to see detailed configuration[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))
