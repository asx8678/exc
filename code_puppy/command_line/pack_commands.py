"""Command handlers for model packs (/pack command).

This module provides the /pack command for viewing and switching between
model packs that define role-based model routing with fallback chains.
"""

from code_puppy.command_line.command_registry import register_command
from code_puppy.messaging import emit_info, emit_warning
from code_puppy.model_packs import (
    get_current_pack,
    get_pack,
    list_packs,
    set_current_pack,
)


@register_command(
    name="pack",
    description="Show or switch model pack (single/coding/economical/capacity)",
    usage="/pack [pack_name]",
    category="config",
)
def handle_pack_command(command: str) -> bool:
    """Handle the /pack command for switching model packs."""
    tokens = command.split()

    # If no pack specified, show current pack and available packs
    if len(tokens) == 1:
        _show_current_pack()
        return True

    # Apply the specified pack
    if len(tokens) == 2:
        pack_name = tokens[1].lower()

        if set_current_pack(pack_name):
            pack = get_pack(pack_name)
            emit_info(f"Description: {pack.description}")

            # Show role breakdown
            roles_info = []
            for role_name, role_config in pack.roles.items():
                if role_config.fallbacks:
                    chain = (
                        f"{role_config.primary} → {', '.join(role_config.fallbacks)}"
                    )
                else:
                    chain = role_config.primary
                roles_info.append(f"  {role_name}: {chain}")

            if roles_info:
                emit_info("Role configuration:")
                for line in roles_info:
                    emit_info(line)

        return True

    # Invalid usage
    emit_warning("Usage: /pack [pack_name]")
    emit_info("Use /pack without arguments to see current pack")
    return True


def _show_current_pack() -> None:
    """Display current pack and available packs."""
    from rich.text import Text

    current_pack = get_current_pack()
    packs = list_packs()

    # Build status message
    lines: list[str] = []
    lines.append("[bold magenta]Model Pack[/bold magenta]")
    lines.append("")
    lines.append(f"[bold]Current pack:[/bold] [cyan]{current_pack.name}[/cyan]")
    lines.append(f"[dim]{current_pack.description}[/dim]")
    lines.append("")

    # Show role breakdown for current pack
    if current_pack.roles:
        lines.append("[bold]Current role configuration:[/bold]")
        for role_name, role_config in current_pack.roles.items():
            if role_config.fallbacks:
                chain = (
                    f"{role_config.primary} → {', '.join(role_config.fallbacks[:2])}"
                )
                if len(role_config.fallbacks) > 2:
                    chain += f" (+{len(role_config.fallbacks) - 2} more)"
            else:
                chain = role_config.primary
            marker = "→ " if role_name == current_pack.default_role else "  "
            lines.append(f"{marker}[cyan]{role_name:<12}[/cyan] {chain}")
        lines.append("")

    lines.append("[bold]Available packs:[/bold]")

    for pack in packs:
        marker = "→ " if pack.name == current_pack.name else "  "
        lines.append(
            f"{marker}[cyan]/{pack.name:<12}[/cyan] [dim]{pack.description}[/dim]"
        )

    lines.append("")
    lines.append("[dim]Use /pack <name> to switch packs[/dim]")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))
