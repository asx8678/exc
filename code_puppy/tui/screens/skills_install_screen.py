"""Skills catalog install screen — Textual replacement for skills_install_menu.py.

Two-panel layout:
  Left  — searchable list of available catalog skills (with installed badge)
  Right — RichLog with skill details (name, description, category, tags, size)

Key bindings:
  Enter — install selected skill (dismisses with skill ID)
  Escape/q — back

Wired via: SkillsScreen 'i' binding → pushes SkillsInstallScreen
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.config_paths import resolve_path
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------


def _load_catalog_skills():
    """Return all skills from the catalog, or [] on failure."""
    try:
        from code_puppy.plugins.agent_skills.skill_catalog import catalog

        return catalog.get_all()
    except Exception:
        return []


def _is_installed(skill_id: str) -> bool:
    """Return True if the skill is already installed locally."""
    return (resolve_path("skills") / skill_id / "SKILL.md").is_file()


def _format_bytes(num_bytes: int) -> str:
    """Format bytes into human-readable string."""
    try:
        size = float(max(0, int(num_bytes)))
    except Exception:
        return "0 B"
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024.0 or unit == "GB":
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} GB"


# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


CATEGORY_ICONS: dict[str, str] = {
    "data": "📊",
    "finance": "💰",
    "legal": "⚖️",
    "office": "📄",
    "biology": "🧬",
    "sales": "💼",
}


class SkillsInstallScreen(MenuScreen):
    """Skill catalog browser — install skills from the remote catalog.

    Left panel: searchable list of all catalog skills.
    Right panel: rich detail view for the highlighted skill.

    Pressing Enter dismisses the screen with the selected skill ID,
    allowing the caller to drive the actual installation.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "install_skill", "Install", show=True),
        Binding("i", "install_skill", "Install", show=False),
    ]

    DEFAULT_CSS = """
    SkillsInstallScreen {
        layers: default;
    }
    SkillsInstallScreen > #screen-title {
        dock: top;
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }
    SkillsInstallScreen SplitPanel {
        height: 1fr;
    }
    SkillsInstallScreen .split-panel--left {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }
    SkillsInstallScreen .split-panel--right {
        width: 1fr;
        padding: 0 1;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._catalog_skills: list = []

    # ------------------------------------------------------------------
    # Compose / Mount
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("📦  Skills Catalog — Install Remote Skills", id="screen-title")
        with SplitPanel(left_title="Catalog", right_title="Details"):
            yield SearchableList(
                placeholder="🔍 Search catalog...",
                id="catalog-list",
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
        """Populate the catalog list."""
        self._catalog_skills = _load_catalog_skills()
        items: list[SearchableListItem] = []
        for entry in self._catalog_skills:
            installed = _is_installed(entry.id)
            icon = CATEGORY_ICONS.get((entry.category or "").lower().strip(), "📁")
            badge = "✓ installed" if installed else entry.category or ""
            items.append(
                SearchableListItem(
                    label=f"{icon} {entry.display_name}",
                    item_id=entry.id,
                    badge=badge,
                )
            )
        catalog_list = self.query_one("#catalog-list", SearchableList)
        catalog_list.add_items(items)
        catalog_list.focus()

        details = self.query_one("#details-panel", RichLog)
        if self._catalog_skills:
            details.write("[dim]Select a skill to see details.[/dim]")
            details.write("[dim]Enter to install · Escape to go back[/dim]")
        else:
            details.write("[yellow]No skills found in catalog.[/yellow]")
            details.write("[dim]Check network connectivity.[/dim]")

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        self._render_details(event.item.item_id)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        self._do_install(event.item.item_id)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_install_skill(self) -> None:
        """Install the highlighted skill."""
        catalog_list = self.query_one("#catalog-list", SearchableList)
        item = catalog_list.highlighted_item
        if item is not None:
            self._do_install(item.item_id)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _do_install(self, skill_id: str) -> None:
        """Dismiss the screen with the chosen skill_id for installation."""
        details = self.query_one("#details-panel", RichLog)
        details.write(f"\n[bold green]→ Selected for install: {skill_id}[/bold green]")
        self.dismiss(skill_id)

    def _get_entry(self, skill_id: str):
        """Find catalog entry by ID."""
        for entry in self._catalog_skills:
            if entry.id == skill_id:
                return entry
        return None

    def _render_details(self, skill_id: str) -> None:
        """Write skill details into the right-panel RichLog."""
        details = self.query_one("#details-panel", RichLog)
        details.clear()

        entry = self._get_entry(skill_id)
        if entry is None:
            details.write("[dim]Select a skill to see details.[/dim]")
            return

        icon = CATEGORY_ICONS.get((entry.category or "").lower().strip(), "📁")
        installed = _is_installed(entry.id)

        details.write(f"[bold cyan]{icon} {entry.display_name}[/bold cyan]")
        details.write("")

        status_str = (
            "[green]✓ Installed[/green]"
            if installed
            else "[yellow]○ Not installed[/yellow]"
        )
        details.write(f"  {status_str}")
        details.write(f"  [dim]ID:[/dim] [cyan]{entry.id}[/cyan]")
        details.write(f"  [dim]Category:[/dim] {entry.category or 'Unknown'}")
        details.write("")

        if entry.description:
            details.write("[bold]Description[/bold]")
            details.write(f"  {entry.description}")
            details.write("")

        if entry.tags:
            details.write("[bold]Tags[/bold]")
            details.write(f"  [cyan]{', '.join(entry.tags[:8])}[/cyan]")
            details.write("")

        # Size / download info
        if entry.zip_size_bytes:
            details.write("[bold]Download Size[/bold]")
            details.write(f"  {_format_bytes(entry.zip_size_bytes)}")
            details.write("")

        # Content flags
        flags = []
        if entry.has_scripts:
            flags.append("📜 scripts")
        if entry.has_references:
            flags.append("🔗 references")
        if entry.file_count:
            flags.append(f"📁 {entry.file_count} files")
        if flags:
            details.write("[bold]Contents[/bold]")
            details.write("  " + "  ".join(flags))
            details.write("")

        details.write("[dim]Press Enter to install · Escape to go back[/dim]")
