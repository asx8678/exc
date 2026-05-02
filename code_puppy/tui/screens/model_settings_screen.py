"""Model settings screen — configure per-model settings.

Replaces code_puppy/command_line/model_settings_menu.py (921 lines).
Two-level navigation: model list → settings for selected model.
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Footer, Label, ListItem, ListView, Static

from code_puppy.command_line.model_settings_menu import (
    SETTING_DEFINITIONS,
    _get_setting_choices,
    _load_all_model_names,
)
from code_puppy.config import (
    get_all_model_settings,
    get_global_model_name,
    model_supports_setting,
    set_model_setting,
)
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# Which panel has focus: "models" or "settings"
_FOCUS_MODELS = "models"
_FOCUS_SETTINGS = "settings"


class SettingItem(ListItem):
    """A list item representing one model setting."""

    def __init__(self, key: str, model_name: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.setting_key = key
        self.model_name = model_name

    def _current_value(self) -> object:
        settings = get_all_model_settings(self.model_name)
        return settings.get(self.setting_key)

    def _display_value(self) -> str:
        val = self._current_value()
        defn = SETTING_DEFINITIONS.get(self.setting_key, {})
        if val is None:
            default = defn.get("default")
            if default is None:
                return "[dim]model default[/dim]"
            return f"[dim]{default} (default)[/dim]"
        fmt = defn.get("format")
        if fmt and defn.get("type") == "numeric":
            try:
                return fmt.format(float(val))
            except TypeError, ValueError:
                pass
        return str(val)

    def compose(self) -> ComposeResult:
        defn = SETTING_DEFINITIONS.get(self.setting_key, {})
        name = defn.get("name", self.setting_key)
        value_str = self._display_value()
        setting_type = defn.get("type", "")
        type_badge = {"numeric": "⟨#⟩", "choice": "⟨☰⟩", "boolean": "⟨✓⟩"}.get(
            setting_type, ""
        )
        yield Label(f"{name}  {type_badge}  {value_str}")


class SettingsPanel(Widget):
    """Right panel: shows configurable settings for a model.

    Handles up/down navigation, left/right value adjustment,
    'd' to reset, and emits `escape` to return to model list.
    """

    DEFAULT_CSS = """
    SettingsPanel {
        height: 1fr;
        padding: 0 1;
    }
    SettingsPanel > #settings-title {
        text-style: bold;
        color: $secondary;
        padding: 1 0;
        height: 3;
    }
    SettingsPanel > #settings-description {
        color: $text-muted;
        height: 3;
        padding-bottom: 1;
    }
    SettingsPanel > #settings-list {
        height: 1fr;
    }
    SettingsPanel > #settings-hints {
        color: $text-muted;
        height: 3;
        padding-top: 1;
        border-top: solid $primary-lighten-3;
    }
    """

    BINDINGS = [
        Binding("left", "adjust_left", "◄ adjust", show=True),
        Binding("right", "adjust_right", "adjust ►", show=True),
        Binding("d", "reset_default", "reset", show=True),
        Binding("escape", "back_to_models", "back", show=True),
    ]

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._model_name: str | None = None
        self._setting_keys: list[str] = []

    def compose(self) -> ComposeResult:
        yield Static("Select a model from the left panel.", id="settings-title")
        yield Static("", id="settings-description")
        yield ListView(id="settings-list")
        yield Static("◄/► adjust  d=reset  ↑↓ navigate  Esc=back", id="settings-hints")

    def load_model(self, model_name: str) -> None:
        """Populate settings for the given model."""
        self._model_name = model_name
        self._setting_keys = [
            k for k in SETTING_DEFINITIONS if model_supports_setting(model_name, k)
        ]

        title = self.query_one("#settings-title", Static)
        title.update(f"⚙ Settings — [bold]{model_name}[/bold]")

        desc = self.query_one("#settings-description", Static)
        desc.update("")

        lv = self.query_one("#settings-list", ListView)
        lv.clear()
        for key in self._setting_keys:
            lv.append(SettingItem(key=key, model_name=model_name))

        self.focus()
        lv.focus()

    def _highlighted_item(self) -> SettingItem | None:
        lv = self.query_one("#settings-list", ListView)
        if lv.highlighted_child and isinstance(lv.highlighted_child, SettingItem):
            return lv.highlighted_child
        return None

    def _refresh_item(self, item: SettingItem) -> None:
        """Rebuild the item label after a value change."""
        item.remove_children()
        defn = SETTING_DEFINITIONS.get(item.setting_key, {})
        name = defn.get("name", item.setting_key)
        setting_type = defn.get("type", "")
        type_badge = {"numeric": "⟨#⟩", "choice": "⟨☰⟩", "boolean": "⟨✓⟩"}.get(
            setting_type, ""
        )
        item.mount(Label(f"{name}  {type_badge}  {item._display_value()}"))
        self._update_description(item)

    def _update_description(self, item: SettingItem | None) -> None:
        desc = self.query_one("#settings-description", Static)
        if item is None:
            desc.update("")
            return
        defn = SETTING_DEFINITIONS.get(item.setting_key, {})
        desc.update(f"[dim]{defn.get('description', '')}[/dim]")

    def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        if isinstance(event.item, SettingItem):
            self._update_description(event.item)

    def action_adjust_left(self) -> None:
        """Decrease numeric value, or cycle choice left, or toggle boolean."""
        self._adjust(-1)

    def action_adjust_right(self) -> None:
        """Increase numeric value, or cycle choice right, or toggle boolean."""
        self._adjust(+1)

    def _adjust(self, direction: int) -> None:
        if self._model_name is None:
            return
        item = self._highlighted_item()
        if item is None:
            return
        key = item.setting_key
        defn = SETTING_DEFINITIONS.get(key, {})
        setting_type = defn.get("type", "")
        current = get_all_model_settings(self._model_name).get(key)

        if setting_type == "numeric":
            step = defn.get("step", 1)
            mn = defn.get("min", 0)
            mx = defn.get("max", 100)
            default = defn.get("default")
            if current is None:
                current = default if default is not None else mn
            try:
                new_val = float(current) + direction * step
            except TypeError, ValueError:
                return
            new_val = max(mn, min(mx, new_val))
            set_model_setting(self._model_name, key, new_val)

        elif setting_type == "choice":
            choices = _get_setting_choices(key, self._model_name)
            if not choices:
                return
            default = defn.get("default", choices[0])
            cur = current if current is not None else default
            try:
                idx = choices.index(str(cur))
            except ValueError:
                idx = 0
            idx = (idx + direction) % len(choices)
            set_model_setting(self._model_name, key, choices[idx])

        elif setting_type == "boolean":
            if current is None:
                current = defn.get("default", False)
            set_model_setting(self._model_name, key, not bool(current))

        self._refresh_item(item)

    def action_reset_default(self) -> None:
        """Reset the highlighted setting to its default value."""
        if self._model_name is None:
            return
        item = self._highlighted_item()
        if item is None:
            return
        set_model_setting(self._model_name, item.setting_key, None)
        self._refresh_item(item)

    def action_back_to_models(self) -> None:
        """Return focus to the model list."""
        screen = self.screen
        if hasattr(screen, "action_focus_models"):
            screen.action_focus_models()


class ModelSettingsScreen(MenuScreen):
    """Textual Screen for per-model settings configuration.

    Replaces the prompt_toolkit ModelSettingsMenu with a proper
    Textual two-panel split screen: searchable model list on the left,
    settings panel on the right.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "select_model", "select", show=True),
    ]

    DEFAULT_CSS = """
    ModelSettingsScreen {
        layers: default;
    }
    ModelSettingsScreen > #screen-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    ModelSettingsScreen SplitPanel {
        height: 1fr;
    }
    ModelSettingsScreen .split-panel--left {
        width: 40%;
        min-width: 30;
        border-right: solid $primary-lighten-2;
    }
    ModelSettingsScreen .split-panel--right {
        width: 1fr;
    }
    """

    focus_target: reactive[str] = reactive(_FOCUS_MODELS)

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._active_model = get_global_model_name()
        self._all_models = _load_all_model_names()

    def compose(self) -> ComposeResult:
        yield Static("⚙  Model Settings", id="screen-title")
        with SplitPanel(left_title="Models", right_title="Settings"):
            yield SearchableList(
                placeholder="🔍 Search models...",
                id="model-list",
                classes="split-panel--left",
            )
            yield SettingsPanel(id="settings-panel", classes="split-panel--right")
        yield Footer()

    def on_mount(self) -> None:
        """Populate the model list after mounting."""
        model_list = self.query_one("#model-list", SearchableList)
        all_settings = {}
        for m in self._all_models:
            try:
                all_settings[m] = get_all_model_settings(m)
            except Exception:
                all_settings[m] = {}

        items = []
        for model_name in self._all_models:
            badge_parts = []
            if model_name == self._active_model:
                badge_parts.append("active")
            settings = all_settings.get(model_name, {})
            has_custom = any(v is not None for v in settings.values())
            if has_custom:
                badge_parts.append("⚙")
            badge = " ".join(badge_parts)
            items.append(
                SearchableListItem(label=model_name, item_id=model_name, badge=badge)
            )
        model_list.add_items(items)
        model_list.focus()

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Handle model selection — load settings for that model."""
        self._load_settings_for(event.item.item_id)

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Update right panel preview on highlight (optional preview)."""
        pass  # Could add a preview here later

    def _load_settings_for(self, model_name: str) -> None:
        """Load settings panel for the named model."""
        panel = self.query_one("#settings-panel", SettingsPanel)
        panel.load_model(model_name)
        self.focus_target = _FOCUS_SETTINGS

    def action_select_model(self) -> None:
        """Select the highlighted model and show its settings."""
        model_list = self.query_one("#model-list", SearchableList)
        item = model_list.highlighted_item
        if item is not None:
            self._load_settings_for(item.item_id)

    def action_focus_models(self) -> None:
        """Return focus to the model list panel."""
        self.focus_target = _FOCUS_MODELS
        self.query_one("#model-list", SearchableList).focus()

    def watch_focus_target(self, target: str) -> None:
        """React to focus target changes."""
        if target == _FOCUS_MODELS:
            self.query_one("#model-list", SearchableList).focus()
