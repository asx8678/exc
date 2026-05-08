"""Command handlers for workflow state (/flags command).

This module provides the /flags command for viewing the current workflow state
and actions taken during the current run.
"""

from code_puppy.command_line.command_registry import register_command
from code_puppy.messaging import emit_info, emit_success, emit_warning
from code_puppy.workflow_state import (
    get_workflow_state,
    reset_workflow_state,
    set_flag,
)


@register_command(
    name="flags",
    description="Show current workflow flags and state",
    usage="/flags [reset|set <flag>|clear <flag>]",
    category="config",
)
def handle_flags_command(command: str) -> bool:
    """Handle the /flags command for viewing workflow state."""
    tokens = command.split()

    # If no subcommand, show current flags
    if len(tokens) == 1:
        _show_workflow_state()
        return True

    subcommand = tokens[1].lower()

    if subcommand == "reset":
        reset_workflow_state()
        emit_success("Workflow state reset")
        return True

    if subcommand == "set" and len(tokens) >= 3:
        flag_name = tokens[2].upper()
        try:
            set_flag(flag_name, True)
            emit_success(f"Flag {flag_name} set")
        except Exception as e:
            emit_warning(f"Could not set flag: {e}")
        return True

    if subcommand == "clear" and len(tokens) >= 3:
        flag_name = tokens[2].upper()
        try:
            set_flag(flag_name, False)
            emit_success(f"Flag {flag_name} cleared")
        except Exception as e:
            emit_warning(f"Could not clear flag: {e}")
        return True

    # Invalid usage
    emit_warning("Usage: /flags [reset|set <flag>|clear <flag>]")
    return True


def _show_workflow_state() -> None:
    """Display current workflow state and flags."""
    from rich.text import Text

    state = get_workflow_state()

    # Build status message
    lines: list[str] = []
    lines.append("[bold magenta]Workflow State[/bold magenta]")
    lines.append("")

    # Show all flags and their status
    all_flags = [
        ("did_generate_code", "Code was generated/modified"),
        ("did_execute_shell", "Shell command executed"),
        ("did_load_context", "Context/files loaded"),
        ("did_create_plan", "Plan created"),
        ("did_encounter_error", "Error occurred"),
        ("needs_user_confirmation", "User confirmation pending"),
        ("did_save_session", "Session saved"),
        ("did_use_fallback_model", "Fallback model used"),
        ("did_trigger_compaction", "Context compacted"),
        ("did_edit_file", "File edited"),
        ("did_create_file", "File created"),
        ("did_delete_file", "File deleted"),
        ("did_run_tests", "Tests run"),
        ("did_check_lint", "Linting performed"),
    ]

    active_count = 0
    for flag_name, description in all_flags:
        is_set = state.has_flag(flag_name.upper())
        if is_set:
            active_count += 1
            marker = "✓"
            color = "green"
        else:
            marker = "○"
            color = "dim"
        lines.append(f"{marker} [{color}]{flag_name:<25}[/{color}] {description}")

    lines.append("")
    lines.append(f"[dim]Active flags: {active_count}/{len(all_flags)}[/dim]")

    # Show metadata if any
    if state.metadata:
        lines.append("")
        lines.append("[bold]Metadata:[/bold]")
        for key, value in sorted(state.metadata.items()):
            lines.append(f"  {key}: {value}")

    status_msg = "\n".join(lines)
    emit_info(Text.from_markup(status_msg))
