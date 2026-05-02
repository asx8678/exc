"""Onboarding wizard screen — Textual replacement for onboarding_wizard.py.

Single panel with Rich-rendered slide content, 5-slide tutorial.

Navigation:
    right / l   — next slide
    left  / h   — previous slide
    down  / j   — next option (on model-selection slide)
    up    / k   — previous option
    enter       — select option and advance
    escape      — skip wizard
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.command_line.onboarding_wizard import (
    OnboardingWizard,
    mark_onboarding_complete,
)
from code_puppy.tui.base_screen import MenuScreen

TOTAL_SLIDES = 5


# ---------------------------------------------------------------------------
# OnboardingScreen
# ---------------------------------------------------------------------------


class OnboardingScreen(MenuScreen):
    """Textual Screen for the first-time onboarding / tutorial wizard.

    Replaces code_puppy/command_line/onboarding_wizard.py interactive TUI.

    5 slides:
        0. Welcome
        1. Model selection  (has ↑↓ options)
        2. MCP servers
        3. Use-case guide
        4. Done!

    Bindings:
        right/l   — next slide (or finish on last slide)
        left/h    — previous slide
        down/j    — next selectable option
        up/k      — previous selectable option
        enter     — select option + advance (or finish)
        escape    — skip wizard
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("right", "next_slide", "Next →", show=True),
        Binding("l", "next_slide", "", show=False),
        Binding("left", "prev_slide", "← Back", show=True),
        Binding("h", "prev_slide", "", show=False),
        Binding("down", "next_option", "↓ Option", show=False),
        Binding("j", "next_option", "", show=False),
        Binding("up", "prev_option", "↑ Option", show=False),
        Binding("k", "prev_option", "", show=False),
        Binding("enter", "select_and_advance", "Select / Next", show=True),
    ]

    CSS = """
    OnboardingScreen {
        layout: vertical;
    }

    #tutorial-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    #slide-content {
        height: 1fr;
        padding: 1 2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._wizard = OnboardingWizard()

    def compose(self) -> ComposeResult:
        yield Static(
            "🐶 Code Puppy Tutorial — ←/→ Navigate · ↑↓ Options · Enter Select",
            id="tutorial-title",
        )
        yield RichLog(id="slide-content", highlight=True, markup=True)
        yield Footer()

    def on_mount(self) -> None:
        """Render first slide and focus the log widget."""
        self._refresh_slide()
        self.query_one("#slide-content", RichLog).focus()

    # --- Helpers -----------------------------------------------------------

    def _refresh_slide(self) -> None:
        """Re-render the current slide into the RichLog."""
        log = self.query_one("#slide-content", RichLog)
        log.clear()

        w = self._wizard
        progress = " ".join(
            "●" if i == w.current_slide else "○" for i in range(TOTAL_SLIDES)
        )
        log.write(f"[dim]{progress}[/dim]")
        log.write(f"[dim]Slide {w.current_slide + 1} of {TOTAL_SLIDES}[/dim]\n")
        log.write(w.get_slide_content())

    def _complete(self) -> None:
        """Mark tutorial complete and dismiss the screen."""
        from code_puppy.messaging import emit_info

        mark_onboarding_complete()
        emit_info("✓ Tutorial completed! Welcome to Code Puppy! 🐶")
        self.app.pop_screen()

    # --- Actions -----------------------------------------------------------

    def action_next_slide(self) -> None:
        """Advance to the next slide, or complete on the last slide."""
        if self._wizard.current_slide >= TOTAL_SLIDES - 1:
            self._complete()
        else:
            self._wizard.next_slide()
            self._refresh_slide()

    def action_prev_slide(self) -> None:
        """Go back one slide."""
        self._wizard.prev_slide()
        self._refresh_slide()

    def action_next_option(self) -> None:
        """Select the next option on slides that have options."""
        self._wizard.next_option()
        self._refresh_slide()

    def action_prev_option(self) -> None:
        """Select the previous option on slides that have options."""
        self._wizard.prev_option()
        self._refresh_slide()

    def action_select_and_advance(self) -> None:
        """Confirm current option selection and advance to next slide."""
        w = self._wizard
        if w.get_options_for_slide():
            w.handle_option_select()

        if w.current_slide >= TOTAL_SLIDES - 1:
            self._complete()
        else:
            w.next_slide()
            self._refresh_slide()

    def action_pop_screen(self) -> None:
        """Skip the tutorial on Escape."""
        from code_puppy.messaging import emit_info

        mark_onboarding_complete()
        emit_info("✓ Tutorial skipped")
        super().action_pop_screen()
