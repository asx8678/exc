"""Fast Puppy Plugin — Native acceleration management (REMOVED).

Native acceleration layer removed. This plugin is now a minimal
stub that only reports that the acceleration layer has been removed.
"""

from code_puppy.callbacks import register_callback


def _on_custom_command(command: str, name: str):
    """Handle /fast_puppy command — reports acceleration removed."""
    if name != "fast_puppy":
        return None
    return "🐍 Fast Puppy: Native acceleration layer removed (removed). All operations use pure Python."


def _on_custom_command_help():
    """Provide help for /fast_puppy command."""
    return [("fast_puppy", "Show status (native acceleration removed)")]


register_callback("custom_command", _on_custom_command)
register_callback("custom_command_help", _on_custom_command_help)
