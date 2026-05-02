"""Shared console utilities for building Rich Console instances.

This module provides a centralized `build_console()` helper to eliminate
duplication of Console construction patterns throughout the codebase.
"""

import sys
from typing import TYPE_CHECKING

from code_puppy.config_package import env_bool

if TYPE_CHECKING:
    from rich.console import Console


def build_console(
    *,
    force_terminal: bool | None = None,
    color_system: str | None = "auto",
    no_color: bool | None = None,
    legacy_windows: bool = False,
    soft_wrap: bool | None = None,
    width: int | None = None,
    file: object | None = None,
    force_interactive: bool | None = None,
    markup: bool | None = None,
) -> "Console":
    """Build a Rich Console with standardized Code Puppy configuration.

    This helper centralizes the common Console construction pattern used
    throughout the codebase, honoring CODE_PUPPY_NO_COLOR and
    CODE_PUPPY_FORCE_COLOR environment variables.

    Args:
        force_terminal: Force terminal detection. If None, determined by
            CODE_PUPPY_FORCE_COLOR env var and stdout.isatty().
        color_system: Color system to use ("auto", "standard", "256", "truecolor", etc.).
            Defaults to "auto", but becomes None when no_color is True.
        no_color: Disable colors. If None, determined by CODE_PUPPY_NO_COLOR env var.
        legacy_windows: Use legacy Windows console support. Defaults to False.
        soft_wrap: Enable soft wrapping. Defaults to None (Rich default).
        width: Console width. Defaults to None (Rich default / auto-detect).
        file: Output file. Defaults to None (stdout).
        force_interactive: Force interactive mode. Defaults to None.
        markup: Enable markup processing. Defaults to None (Rich default).

    Returns:
        Configured Rich Console instance.

    Examples:
        # Standard console with environment variable support
        console = build_console()

        # Console for string capture with forced terminal capabilities
        console = build_console(file=buffer, force_terminal=True, width=80)

        # Console with explicit color control
        console = build_console(no_color=True)
    """
    from rich.console import Console

    # Determine color settings from environment if not explicitly provided
    if no_color is None:
        no_color = env_bool("CODE_PUPPY_NO_COLOR", default=False)

    if force_terminal is None:
        force_color = env_bool("CODE_PUPPY_FORCE_COLOR", default=False)
        force_terminal = force_color or sys.stdout.isatty()

    # Adjust color_system when no_color is enabled
    if no_color and color_system == "auto":
        color_system = None

    # Build kwargs dict to only pass non-None values
    kwargs: dict[str, object] = {
        "force_terminal": force_terminal,
        "color_system": color_system,
        "no_color": no_color,
        "legacy_windows": legacy_windows,
    }

    if soft_wrap is not None:
        kwargs["soft_wrap"] = soft_wrap
    if width is not None:
        kwargs["width"] = width
    if file is not None:
        kwargs["file"] = file
    if force_interactive is not None:
        kwargs["force_interactive"] = force_interactive
    if markup is not None:
        kwargs["markup"] = markup

    return Console(**kwargs)
