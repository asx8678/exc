"""Tab completion system for the Code Puppy TUI input.

Provides slash command completion, file path completion, and model/agent
completion. Shows results in an OptionList overlay above the input.
"""

import os
import sys
from dataclasses import dataclass

from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache

# COMP-L1 fix: Add __slots__ for memory efficiency
# Use slots=True on Python 3.10+, otherwise manual __slots__
if sys.version_info >= (3, 10):

    @dataclass(slots=True)
    class CompletionItem:
        """A single completion suggestion."""

        text: str
        display: str = ""
        description: str = ""

        def __post_init__(self):
            if not self.display:
                self.display = self.text
else:

    @dataclass
    class CompletionItem:
        """A single completion suggestion."""

        __slots__ = ("text", "display", "description")

        text: str
        display: str = ""
        description: str = ""

        def __post_init__(self):
            if not self.display:
                self.display = self.text


# ---------------------------------------------------------------------------
# Cached helpers for expensive completion lookups (COMP-H2 fix)
# These are called per keystroke, so we cache with maxsize=1
# ---------------------------------------------------------------------------


@thread_safe_lru_cache(maxsize=1)
def _get_cached_commands():
    """Get commands from registry - cached to avoid per-keystroke lookup."""
    try:
        from code_puppy.command_line.command_registry import get_unique_commands

        return get_unique_commands()
    except Exception:
        return []


@thread_safe_lru_cache(maxsize=1)
def _get_cached_models_config():
    """Get models config from ModelFactory - cached to avoid per-keystroke lookup."""
    try:
        from code_puppy.model_factory import ModelFactory

        return ModelFactory.load_config()
    except Exception:
        return {}


@thread_safe_lru_cache(maxsize=1)
def _get_cached_agents():
    """Get available agents - cached to avoid per-keystroke lookup."""
    try:
        from code_puppy.agents import get_available_agents

        return get_available_agents()
    except Exception:
        return {}


@thread_safe_lru_cache(maxsize=1)
def _get_cached_config_keys():
    """Get config keys - cached to avoid per-keystroke lookup."""
    try:
        from code_puppy.config import get_config_keys

        return list(get_config_keys())
    except Exception:
        return []


def invalidate_completion_caches():
    """Invalidate all completion caches. Call this when config reloads."""
    _get_cached_commands.cache_clear()
    _get_cached_models_config.cache_clear()
    _get_cached_agents.cache_clear()
    _get_cached_config_keys.cache_clear()


# ---------------------------------------------------------------------------
# Main completion dispatcher
# ---------------------------------------------------------------------------


def get_completions(text: str, cursor_pos: int | None = None) -> list[CompletionItem]:
    """Get completions for the current input text.

    This is the main dispatcher. It checks what kind of completion
    is needed based on the input text and delegates to specific completers.

    Args:
        text: Current input text
        cursor_pos: Cursor position (defaults to end of text)

    Returns:
        List of CompletionItem suggestions
    """
    if cursor_pos is None:
        cursor_pos = len(text)

    text_before_cursor = text[:cursor_pos].lstrip()

    # Slash command completion: /com...
    if text_before_cursor.startswith("/"):
        return _complete_slash_command(text_before_cursor)

    # @ file path completion: @src/...
    if "@" in text_before_cursor:
        return _complete_file_path(text_before_cursor)

    return []


def _complete_slash_command(text: str) -> list[CompletionItem]:
    """Complete slash commands like /model, /settings, /help.

    Also handles subcommands:
    - /model <name> — completes model names
    - /agent <name> — completes agent names
    - /set <key> — completes config keys
    - /cd <path> — completes directory paths
    """
    parts = text.split(None, 1)  # Split on first whitespace
    command = parts[0]  # e.g., "/model"

    if len(parts) == 1 and not text.endswith(" "):
        # Still typing the command name — complete commands
        return _complete_command_names(command)

    # We have a command + subcommand/argument
    arg = parts[1] if len(parts) > 1 else ""
    cmd_lower = command.lower()

    if cmd_lower in ("/model", "/m"):
        return _complete_model_names(arg)
    elif cmd_lower in ("/agent", "/a"):
        return _complete_agent_names(arg)
    elif cmd_lower == "/set":
        return _complete_config_keys(arg)
    elif cmd_lower == "/cd":
        return _complete_directories(arg)

    return []


def _complete_command_names(partial: str) -> list[CompletionItem]:
    """Complete slash command names from the command registry."""
    # Strip the leading /
    partial_name = partial[1:].lower() if partial.startswith("/") else partial.lower()

    items = []
    try:
        commands = _get_cached_commands()

        for cmd in commands:
            if cmd.name.lower().startswith(partial_name):
                items.append(
                    CompletionItem(
                        text=f"/{cmd.name}",
                        display=f"/{cmd.name}",
                        description=cmd.description or "",
                    )
                )
            # Also check aliases
            for alias in getattr(cmd, "aliases", []):
                if alias.lower().startswith(partial_name):
                    items.append(
                        CompletionItem(
                            text=f"/{alias}",
                            display=f"/{alias} → /{cmd.name}",
                            description=cmd.description or "",
                        )
                    )
    except Exception:
        pass

    items.sort(key=lambda c: c.text.lower())
    return items


def _complete_model_names(partial: str) -> list[CompletionItem]:
    """Complete model names for /model command."""
    partial_lower = partial.lower()
    items = []
    try:
        models_config = _get_cached_models_config()
        for name in sorted(models_config.keys()):
            if name.lower().startswith(partial_lower):
                items.append(CompletionItem(text=name, description="model"))
    except Exception:
        pass
    return items


def _complete_agent_names(partial: str) -> list[CompletionItem]:
    """Complete agent names for /agent command."""
    partial_lower = partial.lower()
    items = []
    try:
        agents = _get_cached_agents()
        for name in sorted(agents.keys()):
            display_name = agents[name]
            if name.lower().startswith(partial_lower):
                items.append(
                    CompletionItem(
                        text=name,
                        display=name,
                        description=display_name
                        if isinstance(display_name, str)
                        else str(display_name),
                    )
                )
    except Exception:
        pass
    return items


def _complete_config_keys(partial: str) -> list[CompletionItem]:
    """Complete config keys for /set command."""
    partial_lower = partial.lower()
    items = []
    try:
        from code_puppy.config import get_value

        for key in _get_cached_config_keys():
            if key == "puppy_token":
                continue
            if key.lower().startswith(partial_lower):
                current = get_value(key)
                desc = f"= {current}" if current is not None else ""
                items.append(CompletionItem(text=key, description=desc))
    except Exception:
        pass
    return items


def _complete_file_path(text: str) -> list[CompletionItem]:
    """Complete file paths after @ symbol.

    Uses os.scandir with early-exit at 50 matches BEFORE stat
    to avoid freezing TUI on big repos (COMP-H1 fix).
    """
    # Find the last @ in the text
    at_pos = text.rfind("@")
    if at_pos == -1:
        return []

    partial_path = text[at_pos + 1 :]
    items = []

    try:
        # Determine base directory and prefix
        if partial_path:
            expanded = os.path.expanduser(partial_path)
            if os.path.isdir(expanded):
                base_dir = expanded
                prefix = ""
            else:
                base_dir = os.path.dirname(expanded) or "."
                prefix = os.path.basename(expanded)
        else:
            base_dir = "."
            prefix = ""

        # Use scandir for efficient directory listing
        # Early-exit at 50 matches BEFORE stat (avoid glob + isdir per match)
        prefix_lower = prefix.lower()
        count = 0

        with os.scandir(base_dir) as it:
            for entry in it:
                # Check match before stat - name matching only
                if prefix and not entry.name.lower().startswith(prefix_lower):
                    continue

                # Use entry.is_dir() with follow_symlinks=False (cached from readdir)
                is_dir = entry.is_dir(follow_symlinks=False)
                display_path = entry.name + os.sep if is_dir else entry.name
                icon = "📁" if is_dir else "📄"

                items.append(
                    CompletionItem(
                        text=os.path.join(base_dir, entry.name),
                        display=f"{icon} {display_path}",
                        description="directory" if is_dir else "",
                    )
                )

                count += 1
                if count >= 50:
                    break  # Early-exit at 50 matches

        # Sort results alphabetically
        items.sort(key=lambda x: x.text.lower())
    except Exception:
        pass

    return items  # Already limited to 50 by early-exit


def _complete_directories(partial: str) -> list[CompletionItem]:
    """Complete directory paths for /cd command.

    Uses os.scandir with cached stat results (Issue COMP-M1).
    Sort after filtering with early-exit at match limit.
    """
    items = []
    try:
        expanded = os.path.expanduser(partial) if partial else "."
        if os.path.isdir(expanded):
            base = expanded
            prefix = ""
        else:
            base = os.path.dirname(expanded) or "."
            prefix = os.path.basename(expanded)

        prefix_lower = prefix.lower()
        count = 0
        MAX_MATCHES = 50  # Early-exit limit

        # Use os.scandir which caches stat results from readdir (COMP-M1)
        with os.scandir(base) as it:
            for entry in it:
                # Check name match before expensive ops
                if not entry.name.lower().startswith(prefix_lower):
                    continue

                # entry.is_dir() uses cached stat from scandir (free)
                if entry.is_dir(follow_symlinks=False):
                    display_path = (
                        os.path.join(base, entry.name) if base != "." else entry.name
                    )
                    items.append(
                        CompletionItem(
                            text=display_path + os.sep,
                            display=f"📁 {entry.name}/",
                            description="directory",
                        )
                    )
                    count += 1
                    if count >= MAX_MATCHES:
                        break  # Early-exit at match limit

        # Sort results alphabetically (after filtering, not before)
        items.sort(key=lambda x: x.text.lower())
    except Exception:
        pass
    return items
