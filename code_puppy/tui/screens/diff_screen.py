"""Diff settings screen — configure diff color scheme.

Replaces code_puppy/command_line/diff_menu.py (843 lines) for TUI mode.
Two-panel layout: settings list on left, live diff preview on right.

Import shared data (color palettes, language samples) from the original
diff_menu to avoid duplication.
"""

from rich.console import Group
from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Footer, Label, ListItem, ListView, Static

from code_puppy.command_line.diff_menu import (
    ADDITION_COLORS,
    DELETION_COLORS,
    LANGUAGE_SAMPLES,
    DiffConfiguration,
)
from code_puppy.config import (
    get_diff_addition_color,
    get_diff_deletion_color,
    set_diff_addition_color,
    set_diff_deletion_color,
)
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Focus targets
# ---------------------------------------------------------------------------

_FOCUS_SETTINGS = "settings"


# ---------------------------------------------------------------------------
# DiffColorItem — a single row in the settings list
# ---------------------------------------------------------------------------


class DiffColorItem(ListItem):
    """A list item representing one diff color setting."""

    def __init__(self, setting_type: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.setting_type = setting_type  # "additions" or "deletions"
        self._color_dict = (
            ADDITION_COLORS if setting_type == "additions" else DELETION_COLORS
        )
        self._display_label = (
            "Addition Color" if setting_type == "additions" else "Deletion Color"
        )

        # Seed index from saved config
        current = (
            get_diff_addition_color()
            if setting_type == "additions"
            else get_diff_deletion_color()
        )
        values = list(self._color_dict.values())
        try:
            self._color_index = values.index(current)
        except ValueError:
            self._color_index = 0

    # ------------------------------------------------------------------
    # Rich label helpers
    # ------------------------------------------------------------------

    def _current_color_name(self) -> str:
        return list(self._color_dict.keys())[self._color_index]

    def current_color_value(self) -> str:
        """Return the hex value of the currently selected color."""
        return list(self._color_dict.values())[self._color_index]

    def _format_label(self) -> str:
        name = self._current_color_name()
        value = self.current_color_value()
        return (
            f"[bold]{self._display_label}[/bold]:  "
            f"[{value}]█[/{value}]  {name}  [dim]({value})[/dim]"
        )

    def compose(self) -> ComposeResult:
        yield Label(self._format_label())

    # ------------------------------------------------------------------
    # Cycling / reset
    # ------------------------------------------------------------------

    def cycle_next(self) -> str:
        """Advance one step in the color palette; return new hex value."""
        self._color_index = (self._color_index + 1) % len(self._color_dict)
        self._refresh_label()
        return self.current_color_value()

    def cycle_prev(self) -> str:
        """Go back one step in the color palette; return new hex value."""
        self._color_index = (self._color_index - 1) % len(self._color_dict)
        self._refresh_label()
        return self.current_color_value()

    def reset_default(self) -> str:
        """Reset to the first entry in the palette; return new hex value."""
        self._color_index = 0
        self._refresh_label()
        return self.current_color_value()

    def _refresh_label(self) -> None:
        try:
            label = self.query_one(Label)
            label.update(self._format_label())
        except Exception:
            pass


# ---------------------------------------------------------------------------
# DiffSettingsPanel — left widget
# ---------------------------------------------------------------------------


class DiffSettingsPanel(Widget):
    """Left panel: the two-row settings list (addition / deletion colors)."""

    DEFAULT_CSS = """
    DiffSettingsPanel {
        height: 1fr;
        padding: 0 1;
    }
    DiffSettingsPanel > #settings-title {
        text-style: bold;
        color: $secondary;
        padding: 1 0;
        height: 3;
    }
    DiffSettingsPanel > #settings-list {
        height: 1fr;
    }
    DiffSettingsPanel > #settings-hints {
        color: $text-muted;
        height: 4;
        padding-top: 1;
        border-top: solid $primary-lighten-3;
    }
    """

    BINDINGS = [
        Binding("left", "cycle_left", "◄ prev color", show=True),
        Binding("right", "cycle_right", "next color ►", show=True),
        Binding("d", "reset_default", "reset", show=True),
    ]

    def compose(self) -> ComposeResult:
        yield Static("🎨  Diff Color Settings", id="settings-title")
        yield ListView(id="settings-list")
        yield Static(
            "◄/► cycle color  d=reset  ↑↓ navigate\n[ ] cycle preview language  Esc=back",
            id="settings-hints",
        )

    def on_mount(self) -> None:
        lv = self.query_one("#settings-list", ListView)
        lv.append(DiffColorItem("additions", id="item-additions"))
        lv.append(DiffColorItem("deletions", id="item-deletions"))

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _highlighted_item(self) -> DiffColorItem | None:
        lv = self.query_one("#settings-list", ListView)
        if lv.highlighted_child and isinstance(lv.highlighted_child, DiffColorItem):
            return lv.highlighted_child
        return None

    def _post_change(self, item: DiffColorItem) -> None:
        """Notify the parent screen that a color changed."""
        screen = self.screen
        if hasattr(screen, "_on_color_changed"):
            screen._on_color_changed(item.setting_type, item.current_color_value())

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_cycle_right(self) -> None:
        item = self._highlighted_item()
        if item is None:
            return
        item.cycle_next()
        self._post_change(item)

    def action_cycle_left(self) -> None:
        item = self._highlighted_item()
        if item is None:
            return
        item.cycle_prev()
        self._post_change(item)

    def action_reset_default(self) -> None:
        item = self._highlighted_item()
        if item is None:
            return
        item.reset_default()
        self._post_change(item)


# ---------------------------------------------------------------------------
# DiffPreviewPanel — right widget
# ---------------------------------------------------------------------------


class DiffPreviewPanel(Widget):
    """Right panel: live diff preview rendered natively with Rich."""

    DEFAULT_CSS = """
    DiffPreviewPanel {
        height: 1fr;
        padding: 0 1;
        overflow-y: auto;
    }
    DiffPreviewPanel > #preview-content {
        height: 1fr;
    }
    """

    def __init__(self, config: DiffConfiguration, **kwargs) -> None:
        super().__init__(**kwargs)
        self._config = config

    def compose(self) -> ComposeResult:
        yield Static("Loading preview…", id="preview-content")

    def on_mount(self) -> None:
        self.refresh_preview()

    # ------------------------------------------------------------------
    # Rendering
    # ------------------------------------------------------------------

    def refresh_preview(self) -> None:
        """Re-render the diff preview using the current DiffConfiguration."""
        from code_puppy.tools.common import format_diff_with_colors

        current_lang = self._config.get_current_language()
        filename, sample_diff = LANGUAGE_SAMPLES.get(
            current_lang, LANGUAGE_SAMPLES["python"]
        )

        # Temporarily apply preview colors so format_diff_with_colors picks them up
        original_add = get_diff_addition_color()
        original_del = get_diff_deletion_color()
        try:
            set_diff_addition_color(self._config.current_add_color)
            set_diff_deletion_color(self._config.current_del_color)
            diff_text = format_diff_with_colors(sample_diff)
        finally:
            set_diff_addition_color(original_add)
            set_diff_deletion_color(original_del)

        # Build header as Rich Text
        header = Text()
        header.append("LIVE PREVIEW", style="bold cyan")
        header.append(" — ", style="dim")
        header.append(f"{current_lang.upper()} ({filename})\n", style="bold")
        header.append(
            f"Addition: {self._config.current_add_color}   "
            f"Deletion: {self._config.current_del_color}\n",
            style="dim",
        )
        header.append("[ ] to cycle language\n\n", style="dim italic")

        # Combine into a Group so Static can render both
        renderable = Group(header, diff_text)

        try:
            static = self.query_one("#preview-content", Static)
            static.update(renderable)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# DiffScreen — the top-level Textual Screen
# ---------------------------------------------------------------------------


class DiffScreen(MenuScreen):
    """Textual Screen for diff color configuration.

    Replaces the prompt_toolkit interactive_diff_picker with a proper
    Textual two-panel split screen: settings list on the left,
    live diff preview on the right.

    Keys
    ----
    Up / Down   Navigate between settings
    Left / Right  Cycle colors for the selected setting
    d           Reset selected setting to default
    [ / ]       Cycle preview language left / right
    Escape / Q  Save and exit
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("[", "prev_language", "◄ lang", show=True),
        Binding("]", "next_language", "lang ►", show=True),
        Binding("s", "save_settings", "save", show=True),
    ]

    DEFAULT_CSS = """
    DiffScreen {
        layers: default;
    }
    DiffScreen > #screen-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    DiffScreen SplitPanel {
        height: 1fr;
    }
    DiffScreen .split-panel--left {
        width: 45%;
        min-width: 35;
        border-right: solid $primary-lighten-2;
    }
    DiffScreen .split-panel--right {
        width: 1fr;
    }
    """

    # track pending (unsaved) color changes
    _pending_add_color: reactive[str] = reactive("")
    _pending_del_color: reactive[str] = reactive("")

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._config = DiffConfiguration()

    # ------------------------------------------------------------------
    # Composition
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("🐾  Diff Color Configuration", id="screen-title")
        with SplitPanel(left_title="Settings", right_title="Preview"):
            yield DiffSettingsPanel(id="settings-panel", classes="split-panel--left")
            yield DiffPreviewPanel(
                self._config,
                id="preview-panel",
                classes="split-panel--right",
            )
        yield Footer()

    def on_mount(self) -> None:
        self._pending_add_color = self._config.current_add_color
        self._pending_del_color = self._config.current_del_color
        # Give focus to the list inside the settings panel
        try:
            lv = self.query_one("#settings-list", ListView)
            lv.focus()
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Color change callback (called by DiffSettingsPanel)
    # ------------------------------------------------------------------

    def _on_color_changed(self, setting_type: str, new_value: str) -> None:
        """Update the config and refresh the preview."""
        if setting_type == "additions":
            self._config.current_add_color = new_value
        else:
            self._config.current_del_color = new_value
        self._refresh_preview()

    # ------------------------------------------------------------------
    # Language cycling actions
    # ------------------------------------------------------------------

    def action_prev_language(self) -> None:
        self._config.prev_language()
        self._refresh_preview()

    def action_next_language(self) -> None:
        self._config.next_language()
        self._refresh_preview()

    # ------------------------------------------------------------------
    # Save action
    # ------------------------------------------------------------------

    def action_save_settings(self) -> None:
        """Persist the current color choices to config."""
        if self._config.has_changes():
            set_diff_addition_color(self._config.current_add_color)
            set_diff_deletion_color(self._config.current_del_color)
        self.action_pop_screen()

    # ------------------------------------------------------------------
    # Override pop_screen to auto-save on Esc
    # ------------------------------------------------------------------

    def action_pop_screen(self) -> None:
        """Save changes (if any) before leaving the screen."""
        if self._config.has_changes():
            set_diff_addition_color(self._config.current_add_color)
            set_diff_deletion_color(self._config.current_del_color)
        super().action_pop_screen()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _refresh_preview(self) -> None:
        try:
            panel = self.query_one("#preview-panel", DiffPreviewPanel)
            panel.refresh_preview()
        except Exception:
            pass
