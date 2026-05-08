"""Split panel widget — left list + right preview.

Replaces the prompt_toolkit VSplit + Frame pattern used across 15+ menus.
"""

from textual.app import ComposeResult
from textual.widget import Widget


class SplitPanel(Widget):
    """A horizontal split panel with a left list area and right preview area.

    Usage:
        class MyScreen(MenuScreen):
            def compose(self):
                with SplitPanel():
                    yield MyListWidget(classes="split-panel--left")
                    yield MyPreviewWidget(classes="split-panel--right")
    """

    DEFAULT_CSS = """
    SplitPanel {
        layout: horizontal;
        height: 1fr;
    }
    """

    def __init__(
        self,
        *,
        left_title: str = "",
        right_title: str = "",
        left_min_width: int = 25,
        left_ratio: int = 35,
        name: str | None = None,
        id: str | None = None,
        classes: str | None = None,
    ) -> None:
        super().__init__(name=name, id=id, classes=classes)
        self.left_title = left_title
        self.right_title = right_title
        self.left_min_width = left_min_width
        self.left_ratio = left_ratio

    def compose(self) -> ComposeResult:
        """Yield children — subclasses mount their widgets as children."""
        yield from self._nodes  # type: ignore[attr-defined]
