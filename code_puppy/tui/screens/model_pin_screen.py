"""Model pin picker screen — choose a model to pin to an agent.

Lightweight sub-screen pushed by AgentScreen when the user presses P.
Dismisses with the selected model name (or None to cancel).
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem


class ModelPinScreen(MenuScreen):
    """Pick a model to pin to an agent, or unpin the current one."""

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "confirm_selection", "Select", show=True),
    ]

    CSS = """
    ModelPinScreen {
        layout: vertical;
    }

    #model-pin-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    #model-pin-list {
        height: 1fr;
    }
    """

    def __init__(
        self,
        agent_name: str,
        model_names: list[str],
        current_pinned: str | None,
    ) -> None:
        super().__init__()
        self._agent_name = agent_name
        self._model_names = model_names
        self._current_pinned = current_pinned

    def compose(self) -> ComposeResult:
        yield Static(
            f"📌 Pin model for '{self._agent_name}' — Enter=select  Esc=cancel",
            id="model-pin-title",
        )
        yield SearchableList(
            placeholder="🔍 Search models…",
            id="model-pin-list",
        )
        yield Footer()

    def on_mount(self) -> None:
        """Populate model list."""
        model_list = self.query_one("#model-pin-list", SearchableList)
        items: list[SearchableListItem] = []

        # First choice is always "unpin"
        unpin_badge = "current" if self._current_pinned is None else ""
        items.append(
            SearchableListItem(
                label="(unpin — use default)", item_id="(unpin)", badge=unpin_badge
            )
        )

        for name in self._model_names:
            badge = "pinned" if name == self._current_pinned else ""
            items.append(SearchableListItem(label=name, item_id=name, badge=badge))

        model_list.add_items(items)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Dismiss with the chosen model id."""
        self.dismiss(event.item.item_id)

    def action_confirm_selection(self) -> None:
        """Confirm the highlighted model."""
        model_list = self.query_one("#model-pin-list", SearchableList)
        item = model_list.highlighted_item
        if item:
            self.dismiss(item.item_id)
        else:
            self.dismiss(None)

    def action_pop_screen(self) -> None:
        """Cancel — dismiss with None."""
        self.dismiss(None)

    def action_quit_screen(self) -> None:
        """Cancel — dismiss with None."""
        self.dismiss(None)
