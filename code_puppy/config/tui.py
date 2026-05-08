"""TUI theme, color, and display configuration.

Mirrors ``CodePuppyControl.Config.TUI`` in the Elixir runtime.

Manages banner colors, diff highlight colors, display suppression flags,
and other UI-related settings from ``puppy.cfg``.

Config keys in puppy.cfg:

- ``banner_color_<name>`` — per-banner background color
- ``highlight_addition_color`` — diff addition color
- ``highlight_deletion_color`` — diff deletion color
- ``suppress_thinking_messages`` — hide thinking/reasoning messages
- ``suppress_informational_messages`` — hide info/success/warning messages
- ``grep_output_verbose`` — show full grep output vs. concise
- ``diff_context_lines`` — context lines for diff display (default 6)
"""

from __future__ import annotations

from code_puppy.config.loader import (
    _is_truthy,
    _make_bool_getter,
    _make_int_getter,
    _registered_cache,
    get_value,
    set_config_value,
)

__all__ = [
    "DEFAULT_BANNER_COLORS",
    "get_banner_color",
    "set_banner_color",
    "get_all_banner_colors",
    "reset_banner_color",
    "reset_all_banner_colors",
    "get_diff_addition_color",
    "set_diff_addition_color",
    "get_diff_deletion_color",
    "set_diff_deletion_color",
    "get_suppress_thinking_messages",
    "set_suppress_thinking_messages",
    "get_suppress_informational_messages",
    "set_suppress_informational_messages",
    "get_diff_context_lines",
    "get_grep_output_verbose",
]


# ---------------------------------------------------------------------------
# Default banner colors (jewel-tone palette with semantic meaning)
# ---------------------------------------------------------------------------

DEFAULT_BANNER_COLORS: dict[str, str] = {
    "thinking": "deep_sky_blue4",
    "agent_response": "medium_purple4",
    "shell_command": "dark_orange3",
    "read_file": "steel_blue",
    "edit_file": "dark_goldenrod",
    "create_file": "dark_goldenrod",
    "replace_in_file": "dark_goldenrod",
    "delete_snippet": "dark_goldenrod",
    "grep": "grey37",
    "directory_listing": "dodger_blue2",
    "agent_reasoning": "dark_violet",
    "invoke_agent": "deep_pink4",
    "subagent_response": "sea_green3",
    "list_agents": "dark_slate_gray3",
    "universal_constructor": "dark_cyan",
    "terminal_tool": "dark_goldenrod",
    "mcp_tool_call": "dark_cyan",
    "shell_passthrough": "medium_sea_green",
}


# ---------------------------------------------------------------------------
# Banner colors
# ---------------------------------------------------------------------------


def get_banner_color(banner_name: str) -> str:
    """Get the background color for a specific banner."""
    config_key = f"banner_color_{banner_name}"
    val = get_value(config_key)
    if val:
        return val
    return DEFAULT_BANNER_COLORS.get(banner_name, "blue")


def set_banner_color(banner_name: str, color: str) -> None:
    """Set the background color for a specific banner."""
    config_key = f"banner_color_{banner_name}"
    set_config_value(config_key, color)


def get_all_banner_colors() -> dict[str, str]:
    """Get all banner colors (configured or default)."""
    return {name: get_banner_color(name) for name in DEFAULT_BANNER_COLORS}


def reset_banner_color(banner_name: str) -> None:
    """Reset a banner color to its default."""
    default_color = DEFAULT_BANNER_COLORS.get(banner_name, "blue")
    set_banner_color(banner_name, default_color)


def reset_all_banner_colors() -> None:
    """Reset all banner colors to their defaults."""
    for name, color in DEFAULT_BANNER_COLORS.items():
        set_banner_color(name, color)


# ---------------------------------------------------------------------------
# Diff colors
# ---------------------------------------------------------------------------


@_registered_cache
def get_diff_addition_color() -> str:
    """Get the base color for diff additions. Default: ``#0b1f0b``."""
    val = get_value("highlight_addition_color")
    if val:
        return val
    return "#0b1f0b"


def set_diff_addition_color(color: str) -> None:
    """Set the color for diff additions."""
    set_config_value("highlight_addition_color", color)


@_registered_cache
def get_diff_deletion_color() -> str:
    """Get the base color for diff deletions. Default: ``#390e1a``."""
    val = get_value("highlight_deletion_color")
    if val:
        return val
    return "#390e1a"


def set_diff_deletion_color(color: str) -> None:
    """Set the color for diff deletions."""
    set_config_value("highlight_deletion_color", color)


# ---------------------------------------------------------------------------
# Diff context lines
# ---------------------------------------------------------------------------


get_diff_context_lines = _make_int_getter(
    "diff_context_lines",
    default=6,
    min_val=0,
    max_val=50,
    doc="""Return the number of context lines for diff display (default 6, range 0-50).""",
)


# ---------------------------------------------------------------------------
# Display suppression flags
# ---------------------------------------------------------------------------


get_suppress_thinking_messages = _make_bool_getter(
    "suppress_thinking_messages",
    default=False,
    doc="""Return True if thinking messages are suppressed (default False).""",
)


def set_suppress_thinking_messages(enabled: bool) -> None:
    """Set suppress_thinking_messages."""
    set_config_value("suppress_thinking_messages", "true" if enabled else "false")


def get_suppress_informational_messages() -> bool:
    """Return True if informational messages are suppressed (default False)."""
    return _is_truthy(get_value("suppress_informational_messages"), default=False)


def set_suppress_informational_messages(enabled: bool) -> None:
    """Set suppress_informational_messages."""
    set_config_value("suppress_informational_messages", "true" if enabled else "false")


# ---------------------------------------------------------------------------
# Grep output verbosity
# ---------------------------------------------------------------------------


get_grep_output_verbose = _make_bool_getter(
    "grep_output_verbose",
    default=False,
    doc="""Return True if verbose grep output is enabled (default False).""",
)
