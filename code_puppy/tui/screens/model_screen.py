"""Model picker screen — browse and select active model.

Replaces the interactive_model_picker() that reads from stdin
(which deadlocks in Textual TUI because Textual owns stdin).
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel


def _get_model_entries() -> list[tuple[str, str, bool]]:
    """Return (model_name, display_label, is_current) for all known models."""
    from code_puppy.command_line.model_picker_completion import (
        get_active_model,
        load_model_names,
    )

    model_names = load_model_names()
    try:
        current = get_active_model()
    except Exception:
        current = ""

    entries: list[tuple[str, str, bool]] = []
    for name in sorted(model_names):
        is_current = name == current
        entries.append((name, name, is_current))
    return entries


def _format_model_details(model_name: str, is_current: bool) -> str:
    """Return Rich-markup description for *model_name*."""
    lines: list[str] = []
    lines.append(f"[bold cyan]{model_name}[/bold cyan]")
    lines.append("")
    if is_current:
        lines.append("[bold green]✓ Currently active[/bold green]")
    else:
        lines.append("[dim]Press Enter to activate this model.[/dim]")
    lines.append("")
    # Try to extract provider from model name pattern
    parts = model_name.split("/", 1)
    if len(parts) == 2:
        lines.append(f"[dim]Provider:[/dim] {parts[0]}")
        lines.append(f"[dim]Model ID:[/dim] {parts[1]}")
    elif "claude" in model_name.lower():
        lines.append("[dim]Provider:[/dim] Anthropic")
    elif "gpt" in model_name.lower() or "o1" in model_name.lower():
        lines.append("[dim]Provider:[/dim] OpenAI")
    elif "gemini" in model_name.lower():
        lines.append("[dim]Provider:[/dim] Google")
    elif "llama" in model_name.lower() or "mixtral" in model_name.lower():
        lines.append("[dim]Provider:[/dim] Open-source")
    return "\n".join(lines)


class ModelScreen(MenuScreen):
    """Full-screen model picker with search and details panel.

    Follows the same two-panel layout as AgentScreen and AddModelScreen.
    """

    BINDINGS = [
        Binding("escape", "pop_screen", "Back", show=True),
        Binding("enter", "select_model", "Select", show=True),
    ]

    DEFAULT_CSS = """
    ModelScreen SplitPanel {
        height: 1fr;
    }
    ModelScreen #model-title {
        height: 3;
        content-align: center middle;
        text-style: bold;
        color: $text;
        border-bottom: solid $primary-lighten-3;
        padding: 0 2;
    }
    ModelScreen #model-details {
        padding: 1 2;
    }
    """

    def __init__(self) -> None:
        super().__init__()
        self._entries: list[tuple[str, str, bool]] = []

    def compose(self) -> ComposeResult:
        yield Static(
            "🤖 Select a Model  [dim](↑↓ navigate, Enter select, Esc back)[/dim]",
            id="model-title",
        )
        with SplitPanel(id="model-split"):
            yield SearchableList(placeholder="🔍 Search models...", id="model-list")
            yield RichLog(id="model-details", highlight=True, markup=True, wrap=True)
        yield Footer()

    def on_mount(self) -> None:
        """Populate the model list after mounting."""
        self._entries = _get_model_entries()
        model_list = self.query_one("#model-list", SearchableList)
        items = [
            SearchableListItem(
                label=name,
                item_id=name,
                badge="active" if is_current else "",
            )
            for name, _label, is_current in self._entries
        ]
        model_list.add_items(items)

        # Show details for the currently active model (if any)
        for name, _label, is_current in self._entries:
            if is_current:
                self._show_details(name, is_current)
                break

    def _show_details(self, model_name: str, is_current: bool) -> None:
        """Render model details in the right panel."""
        details = self.query_one("#model-details", RichLog)
        details.clear()
        details.write(_format_model_details(model_name, is_current))

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Update details panel when cursor moves."""
        name = event.item.item_id
        is_current = any(n == name and cur for n, _, cur in self._entries)
        self._show_details(name, is_current)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Activate the selected model."""
        self._activate_model(event.item.item_id)

    def action_select_model(self) -> None:
        """Activate the highlighted model (Enter key)."""
        model_list = self.query_one("#model-list", SearchableList)
        item = model_list.highlighted_item
        if item:
            self._activate_model(item.item_id)

    def _activate_model(self, model_name: str) -> None:
        """Set *model_name* as active and close the screen."""
        try:
            from code_puppy.command_line.model_picker_completion import set_active_model

            set_active_model(model_name)
        except Exception as exc:
            details = self.query_one("#model-details", RichLog)
            details.write(f"[red]Error setting model: {exc}[/red]")
            return

        self.dismiss(model_name)
