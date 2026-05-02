"""
/theme - Switch the Rich syntax highlighting theme at runtime.

Usage:
  /theme            - show current theme and list available
  /theme <name>     - switch to the named theme
  /theme default    - restore default (monokai)

Themes set via CODE_PUPPY_CODE_THEME env var, read by rich_renderer
at render time. Persists only for the current session.
"""

import logging

logger = logging.getLogger(__name__)
import os  # noqa: E402

from code_puppy.callbacks import register_callback  # noqa: E402
from code_puppy.console import build_console  # noqa: E402

COMMAND_NAME = "theme"
DEFAULT_THEME = "monokai"
ENV_VAR = "CODE_PUPPY_CODE_THEME"

# Curated list of themes that look good in both light and dark terminals.
# These are Pygments style names, which Rich's Syntax and Markdown use.
AVAILABLE_THEMES = (
    "monokai",
    "dracula",
    "solarized-dark",
    "solarized-light",
    "github-dark",
    "ansi_dark",
    "ansi_light",
    "one-dark",
    "nord",
    "gruvbox-dark",
    "default",
)


def _get_current_theme() -> str:
    return os.environ.get(ENV_VAR, DEFAULT_THEME)


def _set_theme(name: str) -> None:
    os.environ[ENV_VAR] = name


def _get_console():
    """Get a Console honoring CODE_PUPPY_NO_COLOR and CODE_PUPPY_FORCE_COLOR."""
    return build_console()


def _show_current_and_list(console) -> None:
    from rich.panel import Panel
    from rich.syntax import Syntax
    from rich.table import Table

    current = _get_current_theme()
    console.print(
        Panel(
            f"Current syntax theme: [bold cyan]{current}[/bold cyan]\n"
            f"Usage: [bold]/theme <name>[/bold]",
            title="🎨 Theme",
            border_style="cyan",
        )
    )

    table = Table(
        title="Available Themes", show_header=True, header_style="bold magenta"
    )
    table.add_column("Name", style="cyan")
    table.add_column("Preview")

    sample = "def hello(name):\n    return f'Hi {name}!'"
    for theme in AVAILABLE_THEMES:
        marker = "● " if theme == current else "  "
        try:
            # Render a tiny sample for each theme
            preview = Syntax(sample, "python", theme=theme, background_color="default")
            table.add_row(f"{marker}{theme}", preview)
        except Exception:
            table.add_row(f"{marker}{theme}", "[dim]unavailable[/dim]")
    console.print(table)


def _apply_theme(console, name: str) -> None:
    from rich.syntax import Syntax

    if name not in AVAILABLE_THEMES:
        console.print(f"[yellow]Unknown theme:[/yellow] [bold]{name}[/bold]")
        console.print(f"[dim]Available: {', '.join(AVAILABLE_THEMES)}[/dim]")
        return

    # Try to render a sample with the new theme to verify it works
    try:
        sample = Syntax(
            "def greet(name):\n    return f'Hello, {name}!'",
            "python",
            theme=name,
            background_color="default",
        )
    except Exception as e:
        console.print(f"[red]Theme '{name}' failed to load:[/red] {e}")
        return

    _set_theme(name)
    console.print(f"[green]✓[/green] Theme set to [bold cyan]{name}[/bold cyan]")
    console.print("[dim]Preview:[/dim]")
    console.print(sample)
    console.print(
        "[dim]New code blocks will use this theme. Set permanently with: "
        f"export {ENV_VAR}={name}[/dim]"
    )


def _on_custom_command(command: str, name: str):
    if name != COMMAND_NAME:
        return None

    try:
        console = _get_console()
        # Parse args from the full command string (strip leading /theme)
        parts = command.strip().split(None, 1)
        if len(parts) < 2:
            _show_current_and_list(console)
        else:
            arg = parts[1].strip()
            _apply_theme(console, arg)
    except Exception as e:
        logger.error("theme plugin error: %s", e)
    return True


def _on_custom_command_help():
    return [
        ("/theme", "Show or change the Rich syntax highlighting theme"),
    ]


register_callback("custom_command", _on_custom_command)
register_callback("custom_command_help", _on_custom_command_help)
