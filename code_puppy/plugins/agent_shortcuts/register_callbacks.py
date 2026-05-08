"""Plugin that adds /plan and /lead shortcuts for quick agent switching."""

import uuid
from typing import Literal

from code_puppy.callbacks import register_callback

# Canonical mapping: slash-command name → internal agent name.
# Keep this dict as the single source of truth so renames are one-line fixes.
_SHORTCUTS: dict[str, str] = {
    "plan": "planning-agent",
    "planning": "planning-agent",  # hidden alias
    "lead": "pack-leader",
    "pack": "pack-leader",  # hidden alias
}

# Only these appear in /help. Aliases stay hidden.
_HELP_ENTRIES: list[tuple[str, str]] = [
    ("plan", "Switch to the Planning Agent 📋"),
    ("lead", "Switch to the Pack Leader 🐺"),
]


def _custom_help() -> list[tuple[str, str]]:
    return list(_HELP_ENTRIES)


def _switch_agent(target_name: str, invoked_as: str) -> Literal[True]:
    """Switch to the target agent, preserving context via autosave rotation."""
    # Lazy imports to avoid any plugin-load-time import cycles
    try:
        from code_puppy.agents.agent_manager import (
            get_current_agent,
            set_current_agent,
        )
        from code_puppy.config import finalize_autosave_session
        from code_puppy.messaging import (
            emit_error,
            emit_info,
            emit_success,
            emit_warning,
        )
    except Exception as exc:
        # Absolute fallback — never crash the app
        try:
            from code_puppy.messaging import emit_error

            emit_error(f"/{invoked_as}: failed to import dependencies — {exc}")
        except Exception:
            pass
        return True

    group_id = str(uuid.uuid4())

    try:
        current_agent = get_current_agent()
        if current_agent.name == target_name:
            emit_info(
                f"Already using agent: {current_agent.display_name}",
                message_group=group_id,
            )
            return True

        new_session_id = finalize_autosave_session()

        if not set_current_agent(target_name):
            emit_warning(
                f"Agent switch to '{target_name}' failed after autosave rotation. "
                "Your context was preserved.",
                message_group=group_id,
            )
            return True

        new_agent = get_current_agent()
        try:
            new_agent.reload_code_generation_agent()
        except Exception as exc:
            emit_warning(f"Agent reloaded with warnings: {exc}", message_group=group_id)

        emit_success(
            f"Switched to agent: {new_agent.display_name}", message_group=group_id
        )
        emit_info(new_agent.description, message_group=group_id)
        try:
            from rich.text import Text

            emit_info(
                Text.from_markup(
                    f"[dim]Auto-save session rotated to: {new_session_id}[/dim]"
                ),
                message_group=group_id,
            )
        except Exception:
            emit_info(
                f"Auto-save session rotated to: {new_session_id}",
                message_group=group_id,
            )
        return True
    except Exception as exc:
        emit_error(f"/{invoked_as}: unexpected error — {exc}", message_group=group_id)
        return True


def _handle_custom_command(_command: str, name: str) -> Literal[True] | None:
    """Handle /plan and /lead shortcuts by switching to the appropriate agent."""
    if not name:
        return None
    target = _SHORTCUTS.get(name)
    if target is None:
        return None
    return _switch_agent(target, invoked_as=name)


register_callback("custom_command_help", _custom_help)
register_callback("custom_command", _handle_custom_command)


__all__ = [
    "_custom_help",
    "_handle_custom_command",
    "_switch_agent",
    "_SHORTCUTS",
    "_HELP_ENTRIES",
]
