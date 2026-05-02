"""MCP server catalog browser screen — Textual replacement for install_menu.py.

Two-panel layout:
  Left  — searchable list of available MCP servers from the catalog
  Right — RichLog with server details (name, description, type, tags, env vars)

Enter (or 'i') on a highlighted server dismisses the screen with that server's
ID so the caller can drive the actual installation.

Wired via: /mcp install → app.py pushes MCPScreen
"""

import os
from typing import TYPE_CHECKING

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

if TYPE_CHECKING:
    from code_puppy.mcp_.server_registry_catalog import MCPServerTemplate

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CATEGORY_ICONS: dict[str, str] = {
    "Code": "💻",
    "Storage": "💾",
    "Database": "🗄️",
    "Documentation": "📝",
    "DevOps": "🔧",
    "Monitoring": "📊",
    "Package Management": "📦",
    "Communication": "💬",
    "AI": "🤖",
    "Search": "🔍",
    "Development": "🛠️",
    "Cloud": "☁️",
}

TYPE_ICONS: dict[str, str] = {
    "stdio": "📟",
    "http": "🌐",
    "sse": "📡",
}


# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------


def _load_catalog_servers() -> list["MCPServerTemplate"]:
    """Return all servers from the MCP catalog, or [] on failure."""
    try:
        from code_puppy.mcp_.server_registry_catalog import catalog

        return catalog.servers
    except Exception:
        return []


def _get_server_by_id(server_id: str) -> "MCPServerTemplate | None":
    """Look up a server template by its ID."""
    try:
        from code_puppy.mcp_.server_registry_catalog import catalog

        return catalog.by_id.get(server_id)
    except Exception:
        return None


def _get_mcp_manager():
    """Return the global MCP manager, or None if unavailable."""
    try:
        from code_puppy.mcp_.manager import get_manager

        return get_manager()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


class MCPScreen(MenuScreen):
    """MCP server catalog browser — replaces prompt_toolkit MCPInstallMenu.

    Left panel: searchable list of all catalog servers (with category badge).
    Right panel: rich detail view for the highlighted server.

    Pressing Enter or 'i' dismisses the screen with the selected server's ID,
    allowing the caller to drive installation.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "select_server", "Install", show=True),
        Binding("i", "select_server", "Install", show=False),
    ]

    DEFAULT_CSS = """
    MCPScreen {
        layers: default;
    }
    MCPScreen > #screen-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    MCPScreen SplitPanel {
        height: 1fr;
    }
    MCPScreen .split-panel--left {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }
    MCPScreen .split-panel--right {
        width: 1fr;
        padding: 0 1;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._servers: list["MCPServerTemplate"] = []

    # ------------------------------------------------------------------
    # Compose
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("🔌  MCP Server Catalog", id="screen-title")
        with SplitPanel(left_title="Servers", right_title="Details"):
            yield SearchableList(
                placeholder="🔍 Search servers...",
                id="server-list",
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

    # ------------------------------------------------------------------
    # Mount
    # ------------------------------------------------------------------

    def on_mount(self) -> None:
        """Populate the server list with catalog data."""
        self._servers = _load_catalog_servers()
        items: list[SearchableListItem] = []
        for server in self._servers:
            icon = CATEGORY_ICONS.get(server.category, "📁")
            badges: list[str] = []
            if server.verified:
                badges.append("✓")
            if server.popular:
                badges.append("⭐")
            badge_str = " ".join(badges)
            category_badge = (
                f"{server.category} {badge_str}" if badge_str else server.category
            )
            items.append(
                SearchableListItem(
                    label=f"{icon} {server.display_name}",
                    item_id=server.id,
                    badge=category_badge,
                )
            )

        server_list = self.query_one("#server-list", SearchableList)
        server_list.add_items(items)
        server_list.focus()

        details = self.query_one("#details-panel", RichLog)
        if self._servers:
            details.write("[dim]Select a server to see details.[/dim]")
            details.write("[dim]Press Enter to install • Escape to go back[/dim]")
        else:
            details.write("[yellow]No MCP servers found in catalog.[/yellow]")
            details.write("[dim]Check that code_puppy.mcp_ is available.[/dim]")

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Show server details whenever a list item is highlighted."""
        server = _get_server_by_id(event.item.item_id)
        self._render_server_details(server)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Handle explicit selection (Enter in the list)."""
        self._do_select(event.item.item_id)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_select_server(self) -> None:
        """Install the currently highlighted server."""
        server_list = self.query_one("#server-list", SearchableList)
        item = server_list.highlighted_item
        if item is not None:
            self._do_select(item.item_id)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _do_select(self, server_id: str) -> None:
        """Dismiss the screen, passing the chosen server_id to the caller."""
        server = _get_server_by_id(server_id)
        if server is None:
            return
        details = self.query_one("#details-panel", RichLog)
        details.write(f"\n[bold green]→ Selected: {server.display_name}[/bold green]")
        # Dismiss with the server id so the app can drive installation
        self.dismiss(server_id)

    def _render_server_details(self, server: "MCPServerTemplate | None") -> None:
        """Write server details into the right-panel RichLog."""
        details = self.query_one("#details-panel", RichLog)
        details.clear()

        if server is None:
            details.write("[dim]Select a server to see details.[/dim]")
            return

        icon = CATEGORY_ICONS.get(server.category, "📁")

        # Header
        details.write(f"[bold cyan]{icon} {server.display_name}[/bold cyan]")
        details.write("")

        # Badges
        badges: list[str] = []
        if server.verified:
            badges.append("[green]✓ Verified[/green]")
        if server.popular:
            badges.append("[yellow]⭐ Popular[/yellow]")
        if badges:
            details.write("  " + "  ".join(badges))

        # Meta
        details.write(f"  [dim]Category:[/dim] [cyan]{server.category}[/cyan]")
        type_icon = TYPE_ICONS.get(server.type, "❓")
        details.write(f"  [dim]Type:[/dim] {type_icon} [bold]{server.type}[/bold]")
        details.write("")

        # Description
        details.write("[bold]Description[/bold]")
        details.write(f"  {server.description or 'No description available.'}")
        details.write("")

        # Tags
        if server.tags:
            details.write("[bold]Tags[/bold]")
            details.write(f"  [cyan]{', '.join(server.tags[:8])}[/cyan]")
            details.write("")

        # Environment variables
        env_vars = server.get_environment_vars()
        if env_vars:
            details.write("[bold]🔑 Environment Variables[/bold]")
            for var in env_vars:
                is_set = bool(os.environ.get(var))
                marker = "[green]✓[/green]" if is_set else "[yellow]○[/yellow]"
                details.write(f"  {marker} {var}")
            details.write("")

        # Required tools
        requirements = server.get_requirements()
        if requirements.required_tools:
            details.write("[bold]🛠️ Required Tools[/bold]")
            details.write(f"  {', '.join(requirements.required_tools)}")
            details.write("")

        # Example usage
        if server.example_usage:
            details.write("[bold]💡 Example[/bold]")
            details.write(f"  {server.example_usage}")
            details.write("")

        details.write("[dim]Press Enter or 'i' to install • Escape to go back[/dim]")
