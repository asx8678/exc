"""Completion dropdown overlay for the PuppyInput widget.

Shows a filterable list of completion suggestions that floats
above the input area.
"""

from textual.app import ComposeResult
from textual.message import Message
from textual.widget import Widget
from textual.widgets import OptionList
from textual.widgets.option_list import Option

from code_puppy.tui.completion import CompletionItem


class CompletionOverlay(Widget):
    """A dropdown overlay showing completion suggestions.

    This widget is normally hidden (display: none) and shown
    when completions are available. It sits above the input area.

    Messages:
        CompletionSelected: Fired when user picks a completion
        CompletionDismissed: Fired when overlay is closed without selection
    """

    DEFAULT_CSS = """
    CompletionOverlay {
        dock: bottom;
        height: auto;
        max-height: 10;
        margin: 0 1;
        display: none;
        layer: overlay;
    }

    CompletionOverlay > OptionList {
        height: auto;
        max-height: 10;
        border: solid $accent;
        background: $surface;
    }
    """

    class CompletionSelected(Message):
        """Sent when a completion is selected."""

        def __init__(self, item: CompletionItem) -> None:
            super().__init__()
            self.item = item

    class CompletionDismissed(Message):
        """Sent when the overlay is dismissed."""

        pass

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._items: list[CompletionItem] = []

    def compose(self) -> ComposeResult:
        yield OptionList(id="completion-list")

    def show_completions(self, items: list[CompletionItem]) -> None:
        """Show the overlay with the given completion items."""
        self._items = items
        option_list = self.query_one("#completion-list", OptionList)
        option_list.clear_options()

        for item in items:
            display = item.display
            if item.description:
                display += f"  [dim]{item.description}[/dim]"
            option_list.add_option(Option(display, id=item.text))

        if items:
            self.display = True
            option_list.highlighted = 0
            # Don't steal focus from input — user keeps typing to filter
        else:
            self.hide_overlay()

    def hide_overlay(self) -> None:
        """Hide the completion overlay."""
        self.display = False
        self._items.clear()

    @property
    def is_visible(self) -> bool:
        """Check if overlay is currently showing."""
        return bool(self.display)  # Using Textual's display property directly

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        """Handle selection of a completion item."""
        if event.option.id:
            # Find the matching CompletionItem
            for item in self._items:
                if item.text == event.option.id:
                    self.post_message(self.CompletionSelected(item))
                    break
        self.hide_overlay()

    def on_key(self, event) -> None:
        """Handle escape to dismiss."""
        if event.key == "escape":
            self.hide_overlay()
            self.post_message(self.CompletionDismissed())
            event.prevent_default()
