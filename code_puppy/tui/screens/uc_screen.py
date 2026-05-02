"""Universal Constructor browser screen — Textual replacement for uc_menu.py.

Two-panel layout:
  Left  — searchable list of UC tools (with enabled/disabled badge)
  Right — tool details (name, signature, description, source path)

Pressing Enter on a tool opens an inline source-code sub-screen.
'e' toggles the tool enabled/disabled.
'd' deletes the tool (user-created tools only).
"""

import re
from pathlib import Path

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Data helpers — thin wrappers around the UC registry
# ---------------------------------------------------------------------------


def _get_tool_entries():
    """Return all UC tools sorted by full_name."""
    try:
        from code_puppy.plugins.universal_constructor.registry import get_registry

        registry = get_registry()
        registry.scan()
        return registry.list_tools(include_disabled=True)
    except Exception:
        return []


def _toggle_tool_enabled(tool) -> bool:
    """Toggle a tool's enabled flag in its source file."""
    try:
        source_path = Path(tool.source_path)
        content = source_path.read_text()
        new_enabled = not tool.meta.enabled
        pattern = r'(["\']enabled["\']\s*:\s*)(True|False)'

        def replacer(m):
            return m.group(1) + str(new_enabled)

        new_content, count = re.subn(pattern, replacer, content)
        if count == 0:
            meta_pattern = r"(TOOL_META\s*=\s*\{)"
            new_content, meta_count = re.subn(
                meta_pattern,
                f'\\1\n    "enabled": {new_enabled},',
                content,
            )
            if meta_count == 0:
                return False
        source_path.write_text(new_content)
        return True
    except Exception:
        return False


def _delete_tool(tool) -> bool:
    """Delete a UC tool's source file."""
    try:
        source_path = Path(tool.source_path)
        if not source_path.exists():
            return False
        source_path.unlink()
        # Try to remove now-empty namespace directories
        parent = source_path.parent
        try:
            from code_puppy.plugins.universal_constructor import USER_UC_DIR

            while parent != USER_UC_DIR and parent.exists():
                if not any(parent.iterdir()):
                    parent.rmdir()
                    parent = parent.parent
                else:
                    break
        except Exception:
            pass
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# SourceScreen — sub-screen to view a tool's source code
# ---------------------------------------------------------------------------


class SourceScreen(MenuScreen):
    """Full-screen source code viewer for a UC tool."""

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("up", "scroll_up", "↑", show=False),
        Binding("down", "scroll_down", "↓", show=False),
    ]

    CSS = """
    SourceScreen {
        layout: vertical;
    }
    #source-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }
    #source-log {
        height: 1fr;
        padding: 0 1;
    }
    """

    def __init__(self, tool, **kwargs) -> None:
        super().__init__(**kwargs)
        self._tool = tool

    def compose(self) -> ComposeResult:
        yield Static(
            f"📄 Source: {self._tool.full_name} — Esc to go back",
            id="source-title",
        )
        yield RichLog(id="source-log", highlight=True, markup=True)
        yield Footer()

    def on_mount(self) -> None:
        """Load and display the source code."""
        log = self.query_one("#source-log", RichLog)
        log.clear()
        try:
            from rich.syntax import Syntax

            source_code = Path(self._tool.source_path).read_text()
            log.write(Syntax(source_code, "python", line_numbers=True, theme="monokai"))
        except Exception as exc:
            log.write(f"[red]Error loading source: {exc}[/red]")


# ---------------------------------------------------------------------------
# UCScreen — main UC browser screen
# ---------------------------------------------------------------------------


class UCScreen(MenuScreen):
    """Textual Screen for browsing and managing Universal Constructor tools.

    Replaces code_puppy/command_line/uc_menu.py.

    Bindings:
        enter  — view tool source code (sub-screen)
        e      — toggle tool enabled/disabled
        d      — delete tool (removes source file)
        escape — go back
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "view_source", "View Source", show=True),
        Binding("e", "toggle_enabled", "Toggle Enabled", show=True),
        Binding("d", "delete_tool", "Delete Tool", show=True),
    ]

    CSS = """
    UCScreen {
        layout: vertical;
    }

    #uc-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    SplitPanel {
        height: 1fr;
    }

    #tool-list {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }

    #tool-details {
        height: 1fr;
        padding: 1 2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._tools: list = []

    def compose(self) -> ComposeResult:
        yield Static(
            "🔧 Universal Constructor — ↑↓ Navigate · Enter Source · E Toggle · D Delete",
            id="uc-title",
        )
        with SplitPanel(left_title="Tools", right_title="Details"):
            yield SearchableList(
                placeholder="🔍 Search tools...",
                id="tool-list",
                classes="split-panel--left",
            )
            yield RichLog(
                id="tool-details",
                highlight=True,
                markup=True,
                classes="split-panel--right",
            )
        yield Footer()

    def on_mount(self) -> None:
        """Load tools and populate the list."""
        self._refresh_tools()
        self._populate_list()
        self.query_one("#tool-list", SearchableList).focus()

    # --- Internal helpers --------------------------------------------------

    def _refresh_tools(self) -> None:
        """Reload the tool list from the registry."""
        self._tools = _get_tool_entries()

    def _populate_list(self, keep_selection: str | None = None) -> None:
        """Fill the SearchableList with current tools."""
        tool_list = self.query_one("#tool-list", SearchableList)
        items: list[SearchableListItem] = []
        for tool in self._tools:
            badge = "[on]" if tool.meta.enabled else "[off]"
            if tool.meta.namespace:
                badge += f" ({tool.meta.namespace})"
            items.append(
                SearchableListItem(
                    label=tool.full_name,
                    item_id=tool.full_name,
                    badge=badge,
                )
            )
        if not items:
            items.append(
                SearchableListItem(
                    label="[No UC tools found — ask the LLM to create one!]",
                    item_id="",
                    disabled=True,
                )
            )
        tool_list.add_items(items)

    def _tool_for_id(self, tool_id: str):
        """Find a tool by its full_name."""
        for tool in self._tools:
            if tool.full_name == tool_id:
                return tool
        return None

    def _show_details(self, tool) -> None:
        """Render tool details in the right panel."""
        log = self.query_one("#tool-details", RichLog)
        log.clear()

        log.write("[bold cyan]TOOL DETAILS[/bold cyan]\n")
        log.write(f"[bold]Name:[/bold]        {tool.meta.name}")
        if tool.meta.namespace:
            log.write(f"[bold]Full Name:[/bold]   {tool.full_name}")
        status = (
            "[bold green]ENABLED[/bold green]"
            if tool.meta.enabled
            else "[bold red]DISABLED[/bold red]"
        )
        log.write(f"[bold]Status:[/bold]      {status}")
        log.write(f"[bold]Version:[/bold]     {tool.meta.version}")
        if tool.meta.author:
            log.write(f"[bold]Author:[/bold]      {tool.meta.author}")
        log.write(f"\n[bold]Signature:[/bold]\n[yellow]{tool.signature}[/yellow]")
        log.write(f"\n[bold]Description:[/bold]\n[dim]{tool.meta.description}[/dim]")
        if tool.docstring:
            preview = tool.docstring[:200]
            if len(tool.docstring) > 200:
                preview += "…"
            log.write(f"\n[bold]Docstring:[/bold]\n[dim]{preview}[/dim]")
        log.write(f"\n[bold]Source:[/bold]\n[dim]{tool.source_path}[/dim]")

    # --- Event handlers ----------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Show details when cursor moves to a tool."""
        if event.item.item_id:
            tool = self._tool_for_id(event.item.item_id)
            if tool:
                self._show_details(tool)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Open source viewer when Enter is pressed in the list."""
        if event.item.item_id:
            self._do_view_source(event.item.item_id)

    def on_screen_resume(self) -> None:
        """Refresh after returning from SourceScreen."""
        self._refresh_tools()
        highlighted = self.query_one("#tool-list", SearchableList).highlighted_item
        selected_id = highlighted.item_id if highlighted else None
        self._populate_list(keep_selection=selected_id)

    # --- Actions -----------------------------------------------------------

    def action_view_source(self) -> None:
        """Open the source viewer sub-screen for the highlighted tool."""
        item = self.query_one("#tool-list", SearchableList).highlighted_item
        if item and item.item_id:
            self._do_view_source(item.item_id)

    def _do_view_source(self, tool_id: str) -> None:
        tool = self._tool_for_id(tool_id)
        if tool:
            self.app.push_screen(SourceScreen(tool=tool))

    def action_toggle_enabled(self) -> None:
        """Toggle enabled/disabled for the highlighted tool."""
        from code_puppy.messaging import emit_success, emit_warning

        item = self.query_one("#tool-list", SearchableList).highlighted_item
        if not item or not item.item_id:
            return
        tool = self._tool_for_id(item.item_id)
        if not tool:
            return

        if _toggle_tool_enabled(tool):
            status = "disabled" if tool.meta.enabled else "enabled"
            emit_success(f"Tool '{tool.full_name}' is now {status}")
        else:
            emit_warning(f"Could not toggle tool '{tool.full_name}'")

        selected_id = item.item_id
        self._refresh_tools()
        self._populate_list(keep_selection=selected_id)

    def action_delete_tool(self) -> None:
        """Delete the highlighted tool's source file."""
        from code_puppy.messaging import emit_success, emit_warning

        item = self.query_one("#tool-list", SearchableList).highlighted_item
        if not item or not item.item_id:
            return
        tool = self._tool_for_id(item.item_id)
        if not tool:
            return

        if _delete_tool(tool):
            emit_success(f"Deleted tool '{tool.full_name}'")
        else:
            emit_warning(f"Could not delete tool '{tool.full_name}'")

        self._refresh_tools()
        self._populate_list()
