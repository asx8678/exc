"""Colors configuration screen — Textual replacement for colors_menu.py.

Provides a two-panel split screen:
  Left  — list of all banner types with their current color
  Right — live Rich preview rendered natively by Textual

Access via: /colors command in the TUI.
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widget import Widget
from textual.widgets import Footer, Label, ListItem, ListView, Static

from code_puppy.command_line.colors_menu import (
    BANNER_COLORS,
    BANNER_DISPLAY_INFO,
    BANNER_SAMPLE_CONTENT,
    ColorConfiguration,
)
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Helper: build Rich markup for a single banner row
# ---------------------------------------------------------------------------


def _banner_markup(display_name: str, icon: str, color: str) -> str:
    """Return Rich markup string for a banner header."""
    icon_str = f" {icon}" if icon else ""
    return f"[bold white on {color}] {display_name} [/bold white on {color}]{icon_str}"


# ---------------------------------------------------------------------------
# BannerListItem — one row in the left panel
# ---------------------------------------------------------------------------


class BannerListItem(ListItem):
    """A list item representing one banner type with its current color."""

    def __init__(self, banner_key: str, current_color: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.banner_key = banner_key
        self.current_color = current_color

    def compose(self) -> ComposeResult:
        display_name, icon = BANNER_DISPLAY_INFO[self.banner_key]
        icon_str = f" {icon}" if icon else ""
        yield Label(
            f"{display_name}{icon_str}  [[dim]{self.current_color}[/dim]]",
            markup=True,
        )

    def refresh_color(self, new_color: str) -> None:
        """Rebuild the label after a color change."""
        self.current_color = new_color
        self.remove_children()
        display_name, icon = BANNER_DISPLAY_INFO[self.banner_key]
        icon_str = f" {icon}" if icon else ""
        self.mount(
            Label(
                f"{display_name}{icon_str}  [[dim]{new_color}[/dim]]",
                markup=True,
            )
        )


# ---------------------------------------------------------------------------
# BannerPreviewPanel — right-side live preview widget
# ---------------------------------------------------------------------------


class BannerPreviewPanel(Widget):
    """Right panel — native Rich markup preview of banner colors."""

    DEFAULT_CSS = """
    BannerPreviewPanel {
        height: 1fr;
        padding: 1;
        overflow-y: auto;
    }
    BannerPreviewPanel Static {
        width: 1fr;
    }
    """

    def compose(self) -> ComposeResult:
        yield Static("", id="preview-content", markup=True)

    def render_all_banners(self, config: ColorConfiguration, selected_key: str) -> None:
        """Render all banners with their current colors."""
        lines: list[str] = []
        lines.append("[bold]━━━ Live Preview ━━━[/bold]\n")

        for key in config.banner_keys:
            display_name, icon = BANNER_DISPLAY_INFO[key]
            color = config.current_colors[key]
            sample = BANNER_SAMPLE_CONTENT[key]
            first_sample = sample.split("\n")[0]

            marker = "[bold yellow]▶[/bold yellow] " if key == selected_key else "  "
            banner = _banner_markup(display_name, icon, color)
            lines.append(f"{marker}{banner}")
            lines.append(f"  [dim]{first_sample}[/dim]")
            lines.append("")

        try:
            self.query_one("#preview-content", Static).update("\n".join(lines))
        except Exception:
            pass

    def render_single_banner(self, banner_key: str, color: str) -> None:
        """Render preview for a single banner (used in color picker)."""
        display_name, icon = BANNER_DISPLAY_INFO[banner_key]
        sample = BANNER_SAMPLE_CONTENT[banner_key]

        lines: list[str] = [
            f"[bold]━━━ Editing: {display_name} ━━━[/bold]",
            f" Current color: [bold]{color}[/bold]",
            "",
            _banner_markup(display_name, icon, color),
            "",
            "[dim]Sample content:[/dim]",
        ]
        for line in sample.split("\n")[:3]:
            lines.append(f"[dim]{line}[/dim]")

        try:
            self.query_one("#preview-content", Static).update("\n".join(lines))
        except Exception:
            pass


# ---------------------------------------------------------------------------
# ColorPickerScreen — sub-screen to choose a color for one banner
# ---------------------------------------------------------------------------


class ColorPickerScreen(MenuScreen):
    """Sub-screen for picking a color for a specific banner.

    Pushed on top of ColorsScreen; pops back when the user confirms
    (Enter) or cancels (Escape).
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "confirm_color", "Select", show=True),
    ]

    DEFAULT_CSS = """
    ColorPickerScreen {
        background: $surface;
    }
    ColorPickerScreen > #picker-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    ColorPickerScreen SplitPanel {
        height: 1fr;
    }
    ColorPickerScreen .picker-left {
        width: 35%;
        min-width: 25;
        border-right: solid $primary-lighten-2;
        overflow-y: auto;
    }
    ColorPickerScreen .picker-right {
        width: 1fr;
        padding: 1;
    }
    """

    def __init__(
        self,
        banner_key: str,
        config: ColorConfiguration,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.banner_key = banner_key
        self.config = config
        self._original_color = config.current_colors[banner_key]
        display_name, _ = BANNER_DISPLAY_INFO[banner_key]
        self._display_name = display_name

    def compose(self) -> ComposeResult:
        yield Static(
            f"🎨 Select Color — {self._display_name}",
            id="picker-title",
        )
        with SplitPanel(left_title="Colors", right_title="Preview"):
            yield ListView(id="color-list", classes="picker-left")
            yield BannerPreviewPanel(id="picker-preview", classes="picker-right")
        yield Footer()

    def on_mount(self) -> None:
        """Populate color list with available colors."""
        lv = self.query_one("#color-list", ListView)
        current_color = self._original_color

        for color_name, color_value in BANNER_COLORS.items():
            marker = " ← current" if color_value == current_color else ""
            item = ListItem(Label(f"{color_name}{marker}"))
            # Store data on the item for retrieval in events
            item._color_value = color_value  # type: ignore[attr-defined]
            lv.append(item)

        lv.focus()
        self._update_preview()

    def _update_preview(self) -> None:
        """Refresh the right panel with current working color."""
        color = self.config.current_colors[self.banner_key]
        try:
            preview = self.query_one("#picker-preview", BannerPreviewPanel)
            preview.render_single_banner(self.banner_key, color)
        except Exception:
            pass

    def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        """Live-update preview as cursor moves through color list."""
        item = event.item
        if item and hasattr(item, "_color_value"):
            self.config.current_colors[self.banner_key] = item._color_value  # type: ignore[attr-defined]
            self._update_preview()

    def action_confirm_color(self) -> None:
        """Accept the currently highlighted color and pop back."""
        self.app.pop_screen()

    def action_pop_screen(self) -> None:
        """Cancel — restore original color before popping."""
        self.config.current_colors[self.banner_key] = self._original_color
        super().action_pop_screen()


# ---------------------------------------------------------------------------
# ColorsScreen — main banner-color configuration screen
# ---------------------------------------------------------------------------


class ColorsScreen(MenuScreen):
    """Textual Screen for banner color configuration.

    Replaces code_puppy/command_line/colors_menu.py with a native
    Textual two-panel layout: banner list on left, rich preview on right.

    Bindings:
        Enter  — open color picker for highlighted banner
        s      — save all changes and exit
        r      — reset all banners to defaults
        Escape — discard changes and exit
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "edit_banner", "Edit Color", show=True),
        Binding("s", "save_and_exit", "Save", show=True),
        Binding("r", "reset_defaults", "Reset All", show=True),
    ]

    DEFAULT_CSS = """
    ColorsScreen {
        background: $surface;
    }
    ColorsScreen > #colors-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    ColorsScreen SplitPanel {
        height: 1fr;
    }
    ColorsScreen .colors-left {
        width: 40%;
        min-width: 30;
        border-right: solid $primary-lighten-2;
        overflow-y: auto;
    }
    ColorsScreen .colors-right {
        width: 1fr;
        overflow-y: auto;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._config = ColorConfiguration()

    def compose(self) -> ComposeResult:
        yield Static("🎨  Banner Color Configuration", id="colors-title")
        with SplitPanel(left_title="Banners", right_title="Preview"):
            yield ListView(id="banner-list", classes="colors-left")
            yield BannerPreviewPanel(id="colors-preview", classes="colors-right")
        yield Footer()

    def on_mount(self) -> None:
        """Build the banner list and set initial focus."""
        self._populate_list()
        lv = self.query_one("#banner-list", ListView)
        lv.focus()
        self._refresh_preview()

    # --- Internal helpers --------------------------------------------------

    def _populate_list(self) -> None:
        """(Re)build all banner list items from current config."""
        lv = self.query_one("#banner-list", ListView)
        lv.clear()
        for key in self._config.banner_keys:
            color = self._config.current_colors[key]
            lv.append(BannerListItem(key, color))

    def _selected_key(self) -> str | None:
        """Return the banner key of the highlighted list item."""
        lv = self.query_one("#banner-list", ListView)
        if lv.highlighted_child and isinstance(lv.highlighted_child, BannerListItem):
            return lv.highlighted_child.banner_key
        return self._config.banner_keys[0] if self._config.banner_keys else None

    def _refresh_preview(self) -> None:
        """Update the right-panel preview for the selected banner."""
        key = self._selected_key()
        if key is None:
            return
        try:
            preview = self.query_one("#colors-preview", BannerPreviewPanel)
            preview.render_all_banners(self._config, key)
        except Exception:
            pass

    # --- Event handlers ----------------------------------------------------

    def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        """Refresh preview when the cursor moves to a different banner."""
        if isinstance(event.item, BannerListItem):
            self._refresh_preview()

    def on_screen_resume(self) -> None:
        """Refresh list and preview after returning from ColorPickerScreen."""
        self._populate_list()
        self._refresh_preview()

    # --- Actions -----------------------------------------------------------

    def action_edit_banner(self) -> None:
        """Push the color picker sub-screen for the highlighted banner."""
        key = self._selected_key()
        if key is not None:
            self.app.push_screen(ColorPickerScreen(banner_key=key, config=self._config))

    def action_save_and_exit(self) -> None:
        """Persist all color changes to config and exit."""
        from code_puppy.config import set_banner_color

        for key, color in self._config.current_colors.items():
            set_banner_color(key, color)
        super().action_pop_screen()

    def action_reset_defaults(self) -> None:
        """Reset every banner to its default color."""
        from code_puppy.config import DEFAULT_BANNER_COLORS

        self._config.current_colors = DEFAULT_BANNER_COLORS.copy()
        self._populate_list()
        self._refresh_preview()

    def action_pop_screen(self) -> None:
        """Discard unsaved changes and exit (Escape)."""
        super().action_pop_screen()
