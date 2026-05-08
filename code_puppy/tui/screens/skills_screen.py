"""Skills browser screen — Textual replacement for skills_menu.py.

Two-panel layout:
  Left  — searchable list of installed skills with ✓/✗ enabled/disabled badges
  Right — RichLog with skill details (name, description, tags, path)

Key bindings:
  Enter — toggle enabled/disabled for selected skill
  t     — toggle skills system on/off
  i     — open skills install screen
  Escape/q — back

Wired via: /skills → app.py pushes SkillsScreen
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


def _load_skills_data() -> tuple[list, set[str], bool]:
    """Return (skills, disabled_set, system_enabled). Safe to call; returns empty on error."""
    try:
        from code_puppy.plugins.agent_skills.config import (
            get_disabled_skills,
            get_skills_enabled,
        )
        from code_puppy.plugins.agent_skills.discovery import discover_skills

        skills = discover_skills()
        disabled = get_disabled_skills()
        enabled = get_skills_enabled()
        return skills, disabled, enabled
    except Exception:
        return [], set(), False


def _get_skill_name(skill) -> str:
    """Get display name for a skill, preferring metadata name."""
    try:
        from code_puppy.plugins.agent_skills.metadata import parse_skill_metadata

        meta = parse_skill_metadata(skill.path)
        if meta:
            return meta.name
    except Exception:
        pass
    return getattr(skill, "name", str(skill))


def _get_skill_metadata(skill):
    """Get SkillMetadata for a skill, or None on failure."""
    try:
        from code_puppy.plugins.agent_skills.metadata import parse_skill_metadata

        return parse_skill_metadata(skill.path)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


class SkillsScreen(MenuScreen):
    """Skills browser — replaces prompt_toolkit SkillsMenu.

    Left panel: searchable list of all discovered skills (with status badge).
    Right panel: rich detail view for the highlighted skill.

    Enter toggles the skill on/off.
    't' toggles the skills system globally.
    'i' opens the install catalog.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "toggle_skill", "Toggle", show=True),
        Binding("t", "toggle_system", "Toggle System", show=True),
        Binding("i", "open_install", "Install", show=True),
        Binding("r", "refresh", "Refresh", show=False),
    ]

    DEFAULT_CSS = """
    SkillsScreen {
        layers: default;
    }
    SkillsScreen > #screen-title {
        dock: top;
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }
    SkillsScreen SplitPanel {
        height: 1fr;
    }
    SkillsScreen .split-panel--left {
        width: 38%;
        min-width: 26;
        border-right: solid $primary-lighten-2;
    }
    SkillsScreen .split-panel--right {
        width: 1fr;
        padding: 0 1;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._skills: list = []
        self._disabled: set[str] = set()
        self._system_enabled: bool = False

    # ------------------------------------------------------------------
    # Compose / Mount
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("", id="screen-title")
        with SplitPanel(left_title="Skills", right_title="Details"):
            yield SearchableList(
                placeholder="🔍 Search skills...",
                id="skill-list",
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
        """Populate skill list."""
        self._refresh_data()
        self._populate_list()
        self.query_one("#skill-list", SearchableList).focus()
        details = self.query_one("#details-panel", RichLog)
        details.write("[dim]Select a skill to see details.[/dim]")
        details.write(
            "[dim]Enter=Toggle · t=Toggle System · i=Install · Esc=Back[/dim]"
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _refresh_data(self) -> None:
        self._skills, self._disabled, self._system_enabled = _load_skills_data()
        self._update_title()

    def _update_title(self) -> None:
        status = (
            "[green]ENABLED[/green]" if self._system_enabled else "[red]DISABLED[/red]"
        )
        try:
            self.query_one("#screen-title", Static).update(
                f"🎓  Skills Manager — System: {status}  ({len(self._skills)} skills)"
            )
        except Exception:
            pass

    def _populate_list(self) -> None:
        items: list[SearchableListItem] = []
        for skill in self._skills:
            name = _get_skill_name(skill)
            is_disabled = name in self._disabled
            badge = "✗ disabled" if is_disabled else "✓ enabled"
            items.append(
                SearchableListItem(
                    label=name,
                    item_id=name,
                    badge=badge,
                    disabled=is_disabled,
                )
            )
        skill_list = self.query_one("#skill-list", SearchableList)
        skill_list.add_items(items)

    def _render_skill_details(self, skill_name: str) -> None:
        details = self.query_one("#details-panel", RichLog)
        details.clear()

        # Find skill by name
        skill = None
        for s in self._skills:
            if _get_skill_name(s) == skill_name:
                skill = s
                break

        if skill is None:
            details.write("[dim]Select a skill to see details.[/dim]")
            return

        is_disabled = skill_name in self._disabled
        status_str = "[red]Disabled[/red]" if is_disabled else "[green]Enabled[/green]"

        details.write(f"[bold cyan]{skill_name}[/bold cyan]")
        details.write(f"  [bold]Status:[/bold] {status_str}")
        details.write("")

        meta = _get_skill_metadata(skill)
        if meta:
            if meta.description:
                details.write("[bold]Description[/bold]")
                details.write(f"  [dim]{meta.description}[/dim]")
                details.write("")
            if meta.tags:
                details.write("[bold]Tags[/bold]")
                details.write(f"  [cyan]{', '.join(meta.tags)}[/cyan]")
                details.write("")

        # Path
        path_str = str(getattr(skill, "path", "unknown"))
        if len(path_str) > 55:
            path_str = "..." + path_str[-52:]
        details.write("[bold]Path[/bold]")
        details.write(f"  [dim]{path_str}[/dim]")
        details.write("")
        details.write("[dim]Enter=Toggle · t=Toggle System · Esc=Back[/dim]")

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        self._render_skill_details(event.item.item_id)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        self.action_toggle_skill()

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_toggle_skill(self) -> None:
        """Toggle the highlighted skill enabled/disabled."""
        skill_list = self.query_one("#skill-list", SearchableList)
        item = skill_list.highlighted_item
        if item is None:
            return
        try:
            from code_puppy.plugins.agent_skills.config import set_skill_disabled
            from code_puppy.plugins.agent_skills.discovery import refresh_skill_cache

            is_disabled = item.item_id in self._disabled
            set_skill_disabled(item.item_id, not is_disabled)
            refresh_skill_cache()
        except Exception:
            pass
        self._refresh_data()
        self._populate_list()
        self._render_skill_details(item.item_id)

    def action_toggle_system(self) -> None:
        """Toggle the skills system on/off globally."""
        try:
            from code_puppy.plugins.agent_skills.config import set_skills_enabled

            set_skills_enabled(not self._system_enabled)
        except Exception:
            pass
        self._refresh_data()

    def action_open_install(self) -> None:
        """Open the skills install screen."""
        from code_puppy.tui.screens.skills_install_screen import SkillsInstallScreen

        self.app.push_screen(SkillsInstallScreen())

    def action_refresh(self) -> None:
        """Refresh the skills list from disk."""
        try:
            from code_puppy.plugins.agent_skills.discovery import refresh_skill_cache

            refresh_skill_cache()
        except Exception:
            pass
        self._refresh_data()
        self._populate_list()
