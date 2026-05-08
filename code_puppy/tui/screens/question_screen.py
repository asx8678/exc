"""Question screen — interactive question picker for ask_user_question tool.

Replaces code_puppy/tools/ask_user_question/tui_loop.py + terminal_ui.py.

"""

from typing import Any

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.screen import Screen
from textual.widgets import Footer, Input, RichLog, Static

from code_puppy.tools.ask_user_question.constants import (
    AUTO_ADD_OTHER_OPTION,
    OTHER_OPTION_LABEL,
)
from code_puppy.tools.ask_user_question.models import Question, QuestionAnswer
from code_puppy.tools.ask_user_question.terminal_ui import QuestionUIState

# Return type: (answers, cancelled, timed_out)
QuestionResult = tuple[list[QuestionAnswer], bool, bool]


class QuestionScreen(Screen[QuestionResult]):
    """Textual Screen for interactive question answering.
    Bindings: ←/→ switch question · ↑/↓ navigate options · Space toggle
    Enter confirm/advance · Ctrl+S submit all · Escape cancel.
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
        Binding("ctrl+s", "submit_all", "Submit All", show=True),
        Binding("enter", "confirm", "Confirm", show=True),
        Binding("space", "toggle_option", "Toggle", show=True),
        Binding("up", "prev_option", "↑ Opt", show=False),
        Binding("down", "next_option", "↓ Opt", show=False),
        Binding("k", "prev_option", "", show=False),
        Binding("j", "next_option", "", show=False),
        Binding("left", "prev_question", "← Q", show=False),
        Binding("right", "next_question", "→ Q", show=False),
        Binding("h", "prev_question", "", show=False),
        Binding("l", "next_question", "", show=False),
    ]

    CSS = """
    QuestionScreen {
        layout: vertical;
    }

    #q-header {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    #q-text {
        height: 4;
        padding: 1 2;
        background: $surface;
        border-bottom: solid $primary-lighten-2;
    }

    #q-panels {
        height: 1fr;
        layout: horizontal;
    }

    #q-left {
        width: 30%;
        min-width: 18;
        border-right: solid $primary-lighten-2;
        padding: 0 1;
    }

    #q-right {
        width: 1fr;
        padding: 0 1;
    }

    #q-other-input {
        height: 3;
        margin: 0 1;
        display: none;
    }

    #q-other-input.visible {
        display: block;
    }

    #q-timeout {
        height: 1;
        background: $warning-darken-2;
        color: $text;
        padding: 0 2;
        display: none;
    }

    #q-timeout.visible {
        display: block;
    }
    """

    def __init__(
        self,
        questions: list[Question],
        timeout_seconds: int = 300,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self._state = QuestionUIState(questions)
        self._state.timeout_seconds = timeout_seconds

    def compose(self) -> ComposeResult:
        yield Static(
            "❓ Questions — ←/→ Switch · ↑/↓ Navigate"
            " · Space Toggle · Enter Confirm · Ctrl+S Submit All",
            id="q-header",
        )
        yield Static("", id="q-text", markup=True)
        with Horizontal(id="q-panels"):
            yield RichLog(id="q-left", markup=True, highlight=False)
            yield RichLog(id="q-right", markup=True, highlight=False)
        yield Input(
            placeholder="Type custom answer and press Enter to confirm…",
            id="q-other-input",
        )
        yield Static("", id="q-timeout", markup=True)
        yield Footer()

    def on_mount(self) -> None:
        """Populate panels and start the timeout ticker."""
        self._refresh_all()
        self.query_one("#q-right", RichLog).focus()
        self.set_interval(1.0, self._on_timer_tick)

    def _render_left_panel(self) -> None:
        """Rebuild the question-headers list on the left."""
        log = self.query_one("#q-left", RichLog)
        log.clear()
        for i, q in enumerate(self._state.questions):
            answered = self._state.is_question_answered(i)
            is_current = i == self._state.current_question_index
            check = "✓" if answered else " "

            if is_current:
                log.write(f"[bold yellow]▶ {check} {q.header}[/bold yellow]")
            elif answered:
                log.write(f"[green]  {check} {q.header}[/green]")
            else:
                log.write(f"[dim]    {q.header}[/dim]")

        log.write("")
        log.write("[dim]← → switch question[/dim]")
        log.write("[dim]↑ ↓ navigate options[/dim]")
        log.write("[dim]Ctrl+S submit all[/dim]")

    def _render_right_panel(self) -> None:
        """Rebuild the options list for the current question."""
        log = self.query_one("#q-right", RichLog)
        log.clear()
        state = self._state
        q = state.current_question

        type_label = "multi-select ☑" if q.multi_select else "single-select ●"
        log.write(f"[dim]({type_label})[/dim]")
        log.write("")

        for i, opt in enumerate(q.options):
            self._write_option_row(log, i, opt.label, opt.description, q.multi_select)

        if AUTO_ADD_OTHER_OPTION:
            other_idx = len(q.options)
            other_text = state.get_other_text_for_question(state.current_question_index)
            extra = f" — [italic]{other_text}[/italic]" if other_text else ""
            self._write_option_row(
                log,
                other_idx,
                f"{OTHER_OPTION_LABEL}{extra}",
                "",
                q.multi_select,
            )

        if state.entering_other_text:
            log.write("")
            log.write("[bold yellow]📝 Type your answer below:[/bold yellow]")

    def _write_option_row(
        self,
        log: RichLog,
        idx: int,
        label: str,
        description: str,
        multi_select: bool,
    ) -> None:
        """Write one option row into *log*."""
        state = self._state
        is_selected = state.is_option_selected(idx)
        is_cursor = state.current_cursor == idx

        sel_marker = (
            ("[green]☑[/green]" if is_selected else "☐")
            if multi_select
            else ("[green]●[/green]" if is_selected else "○")
        )
        cursor_str = "[bold yellow]▶[/bold yellow]" if is_cursor else " "

        if is_cursor:
            label_fmt = f"[bold]{label}[/bold]"
        elif is_selected:
            label_fmt = f"[green]{label}[/green]"
        else:
            label_fmt = label

        log.write(f" {cursor_str} {sel_marker}  {label_fmt}")
        if description and is_cursor:
            log.write(f"      [dim]{description}[/dim]")

    def _update_question_text(self) -> None:
        """Update the question-text strip above the panels."""
        q = self._state.current_question
        total = len(self._state.questions)
        idx = self._state.current_question_index + 1
        mode = "multi-select" if q.multi_select else "single-select"
        self.query_one("#q-text", Static).update(
            f"[bold]Q {idx}/{total}[/bold] [dim]({mode})[/dim]\n\n{q.question}"
        )

    def _update_other_input(self) -> None:
        """Show/hide the 'Other' text input widget."""
        inp = self.query_one("#q-other-input", Input)
        if self._state.entering_other_text:
            inp.add_class("visible")
            # Sync buffer → widget value only when it diverges
            if inp.value != self._state.other_text_buffer:
                inp.value = self._state.other_text_buffer
            inp.focus()
        else:
            inp.remove_class("visible")
            try:
                self.query_one("#q-right", RichLog).focus()
            except Exception:
                pass

    def _update_timeout_display(self) -> None:
        """Show/hide the timeout countdown bar."""
        status = self.query_one("#q-timeout", Static)
        if self._state.should_show_timeout_warning():
            remaining = self._state.get_time_remaining()
            status.add_class("visible")
            status.update(
                f"[bold red]⏱ Timing out in {remaining}s[/bold red]"
                " — press any key to reset, Ctrl+S to submit"
            )
        else:
            status.remove_class("visible")

    def _refresh_all(self) -> None:
        """Full UI refresh (questions + options + text + other input + timer)."""
        self._render_left_panel()
        self._render_right_panel()
        self._update_question_text()
        self._update_other_input()
        self._update_timeout_display()

    async def _on_timer_tick(self) -> None:
        """Called every second by set_interval to check for timeout."""
        if self._state.is_timed_out():
            self.dismiss(([], False, True))
            return
        self._update_timeout_display()

    def action_cancel(self) -> None:
        """Escape: exit Other-text mode, or cancel."""
        self._state.reset_activity_timer()
        if self._state.entering_other_text:
            self._state.entering_other_text = False
            self._state.other_text_buffer = ""
            self._refresh_all()
            return
        self.dismiss(([], True, False))

    def action_submit_all(self) -> None:
        """Ctrl+S: submit all answers immediately."""
        self._state.reset_activity_timer()
        if self._state.entering_other_text:
            self._state.commit_other_text()
        self.dismiss((self._state.build_answers(), False, False))

    def action_confirm(self) -> None:
        """Enter: select/confirm and advance or submit."""
        self._state.reset_activity_timer()

        if self._state.entering_other_text:
            self._state.commit_other_text()
            self._refresh_all()
            return

        if self._state.is_other_option(self._state.current_cursor):
            self._state.enter_other_text_mode()
            self._refresh_all()
            return

        is_last = self._state.current_question_index == len(self._state.questions) - 1
        cursor_on_selected = self._state.is_option_selected(self._state.current_cursor)

        if not self._state.current_question.multi_select:
            self._state.select_current_option()

        if not is_last:
            self._state.next_question()
            self._refresh_all()
        else:
            # On last question: only submit when confirming an already-selected option
            if cursor_on_selected:
                self.dismiss((self._state.build_answers(), False, False))
            else:
                self._refresh_all()

    def action_toggle_option(self) -> None:
        """Space: toggle checkbox (multi) or select radio (single)."""
        self._state.reset_activity_timer()

        if self._state.entering_other_text:
            # Let space type in the input widget naturally (handled by Input)
            return

        if self._state.is_other_option(self._state.current_cursor):
            self._state.enter_other_text_mode()
            self._refresh_all()
            return

        if self._state.current_question.multi_select:
            self._state.toggle_current_option()
        else:
            self._state.select_current_option()
        self._refresh_all()

    def action_prev_option(self) -> None:
        """Up / k: move option cursor up."""
        if self._state.entering_other_text:
            return
        self._state.reset_activity_timer()
        self._state.move_cursor_up()
        self._render_right_panel()

    def action_next_option(self) -> None:
        """Down / j: move option cursor down."""
        if self._state.entering_other_text:
            return
        self._state.reset_activity_timer()
        self._state.move_cursor_down()
        self._render_right_panel()

    def action_prev_question(self) -> None:
        """Left / h: switch to previous question."""
        if self._state.entering_other_text:
            return
        self._state.reset_activity_timer()
        self._state.prev_question()
        self._refresh_all()

    def action_next_question(self) -> None:
        """Right / l: switch to next question."""
        if self._state.entering_other_text:
            return
        self._state.reset_activity_timer()
        self._state.next_question()
        self._refresh_all()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Commit Other text when Enter is pressed inside the input."""
        if event.input.id == "q-other-input":
            self._state.other_text_buffer = event.value
            self._state.commit_other_text()
            self._refresh_all()

    def on_input_changed(self, event: Input.Changed) -> None:
        """Sync state buffer with Input widget value."""
        if event.input.id == "q-other-input" and self._state.entering_other_text:
            self._state.other_text_buffer = event.value
            self._state.reset_activity_timer()
