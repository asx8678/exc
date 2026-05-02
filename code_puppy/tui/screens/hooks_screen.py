"""Hooks browser screen — Textual replacement for hooks_menu.py.

Two-panel layout:
  Left  — searchable list of hooks from both global and project sources
  Right — RichLog with hook details (event type, matcher, command, source)

Read-only browser — no editing, just inspection.

Key bindings:
  r     — refresh hooks list
  Escape/q — back

Wired via: /hooks → app.py pushes HooksScreen
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------


def _load_hooks() -> list:
    """Return all hook entries from global and project sources, or [] on error."""
    try:
        from code_puppy.plugins.hook_manager.config import flatten_all_hooks

        return flatten_all_hooks()
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


class HooksScreen(MenuScreen):
    """Hooks browser — read-only view of all configured hooks.

    Left panel: searchable list of all hooks (project + global).
    Right panel: rich detail view for the highlighted hook.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("r", "refresh", "Refresh", show=True),
    ]

    DEFAULT_CSS = """
    HooksScreen {
        layers: default;
    }
    HooksScreen > #screen-title {
        dock: top;
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }
    HooksScreen SplitPanel {
        height: 1fr;
    }
    HooksScreen .split-panel--left {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }
    HooksScreen .split-panel--right {
        width: 1fr;
        padding: 0 1;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._hooks: list = []

    # ------------------------------------------------------------------
    # Compose / Mount
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("", id="screen-title")
        with SplitPanel(left_title="Hooks", right_title="Details"):
            yield SearchableList(
                placeholder="🔍 Search hooks...",
                id="hook-list",
                classes="split-panel--left",
            )
            yield RichLog(
                id="details-panel",
                classes="split-panel--right",
                markup=True,
                highlight=False,
                wrap=True,
            )
        yield Footer()

    def on_mount(self) -> None:
        """Load hooks."""
        self._refresh_data()
        self._populate_list()
        self.query_one("#hook-list", SearchableList).focus()
        details = self.query_one("#details-panel", RichLog)
        details.write("[dim]Select a hook to see details.[/dim]")
        details.write("[dim]r=Refresh · Esc=Back[/dim]")

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _refresh_data(self) -> None:
        self._hooks = _load_hooks()
        enabled_count = sum(1 for h in self._hooks if h.enabled)
        project_count = sum(1 for h in self._hooks if h.source == "project")
        global_count = sum(1 for h in self._hooks if h.source == "global")
        try:
            self.query_one("#screen-title", Static).update(
                f"🪝  Hooks Browser — {enabled_count}/{len(self._hooks)} enabled"
                f"  ({project_count} project, {global_count} global)"
            )
        except Exception:
            pass

    def _populate_list(self) -> None:
        items: list[SearchableListItem] = []
        for idx, hook in enumerate(self._hooks):
            status_icon = "✓" if hook.enabled else "✗"
            source_icon = "🌍" if hook.source == "global" else "📁"
            label = f"{source_icon} [{hook.event_type}] {hook.display_matcher}"
            badge = f"{status_icon} {hook.source}"
            items.append(
                SearchableListItem(
                    label=label,
                    item_id=str(idx),
                    badge=badge,
                    disabled=not hook.enabled,
                )
            )
        hook_list = self.query_one("#hook-list", SearchableList)
        hook_list.add_items(items)

    def _render_hook_details(self, hook_idx: int) -> None:
        details = self.query_one("#details-panel", RichLog)
        details.clear()

        if hook_idx < 0 or hook_idx >= len(self._hooks):
            details.write("[dim]Select a hook to see details.[/dim]")
            return

        hook = self._hooks[hook_idx]
        status_str = "[green]Enabled[/green]" if hook.enabled else "[red]Disabled[/red]"
        source_label = (
            "Global (~/.code_puppy/hooks.json)"
            if hook.source == "global"
            else "Project (.claude/settings.json)"
        )
        source_color = "blue" if hook.source == "global" else "green"

        details.write("[bold cyan]HOOK DETAILS[/bold cyan]")
        details.write("")
        details.write(f"  [bold]Status:[/bold]   {status_str}")
        details.write(
            f"  [bold]Source:[/bold]   [{source_color}]{source_label}[/{source_color}]"
        )
        details.write(f"  [bold]Event:[/bold]    [cyan]{hook.event_type}[/cyan]")
        details.write("")
        details.write("[bold]Matcher[/bold]")
        details.write(f"  [yellow]{hook.matcher}[/yellow]")
        details.write("")
        label = "Command" if hook.hook_type == "command" else "Prompt"
        details.write(f"[bold]{label}[/bold]")
        details.write(f"  [dim]{hook.command}[/dim]")
        details.write("")
        details.write(f"  [bold]Type:[/bold]     [dim]{hook.hook_type}[/dim]")
        details.write(f"  [bold]Timeout:[/bold]  [dim]{hook.timeout} ms[/dim]")
        if hook.hook_id:
            details.write(f"  [bold]ID:[/bold]       [dim]{hook.hook_id}[/dim]")
        details.write("")
        details.write(
            f"  [dim]group #{hook._group_index}  hook #{hook._hook_index}[/dim]"
        )
        details.write("")
        details.write("[dim]r=Refresh · Esc=Back[/dim]")

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        try:
            idx = int(event.item.item_id)
        except ValueError, TypeError:
            idx = -1
        self._render_hook_details(idx)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_refresh(self) -> None:
        """Reload hooks from both sources."""
        self._refresh_data()
        self._populate_list()
        details = self.query_one("#details-panel", RichLog)
        details.clear()
        details.write("[dim]Refreshed.[/dim]")
        details.write("[dim]Select a hook to see details.[/dim]")
