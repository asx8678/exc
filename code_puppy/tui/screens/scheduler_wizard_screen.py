"""Scheduler wizard screen — Textual replacement for scheduler_wizard.py.

Simple form for creating a new scheduled task:
  - Task name (Input)
  - Cron / interval expression (Input)
  - Agent name (Input)
  - Prompt text (Input)
  - Working directory (Input)

Ctrl+S — save and dismiss with task data dict
Escape  — cancel, dismiss with None

Wired via: SchedulerScreen 'n' binding → pushes SchedulerWizardScreen
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, Input, Label, Static

from code_puppy.tui.base_screen import MenuScreen

# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


class SchedulerWizardScreen(MenuScreen):
    """Simple task creation form.

    Ctrl+S saves the task; Escape cancels.
    Dismisses with a dict of task data or None if cancelled.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("ctrl+s", "save_task", "Save", show=True),
    ]

    DEFAULT_CSS = """
    SchedulerWizardScreen {
        layers: default;
    }
    SchedulerWizardScreen > #wizard-title {
        dock: top;
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }
    SchedulerWizardScreen > #wizard-body {
        height: 1fr;
        padding: 1 2;
    }
    SchedulerWizardScreen Label {
        margin-top: 1;
        color: $text-muted;
        text-style: bold;
    }
    SchedulerWizardScreen Input {
        margin-bottom: 0;
    }
    SchedulerWizardScreen > #status-line {
        dock: bottom;
        height: 1;
        color: $text-muted;
        padding: 0 2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)

    # ------------------------------------------------------------------
    # Compose
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("📅  Create Scheduled Task", id="wizard-title")
        yield Label("Task Name", classes="field-label")
        yield Input(
            placeholder="e.g., Daily Code Review",
            id="field-name",
        )
        yield Label(
            "Schedule (interval like 15m, 1h, 2d  OR  cron: 0 9 * * *)",
            classes="field-label",
        )
        yield Input(
            placeholder="e.g., 1h  or  0 9 * * *",
            id="field-schedule",
        )
        yield Label("Agent", classes="field-label")
        yield Input(
            placeholder="code-puppy",
            id="field-agent",
        )
        yield Label("Model (leave blank for default)", classes="field-label")
        yield Input(
            placeholder="(default)",
            id="field-model",
        )
        yield Label("Prompt", classes="field-label")
        yield Input(
            placeholder="What should the agent do?",
            id="field-prompt",
        )
        yield Label("Working Directory", classes="field-label")
        yield Input(
            placeholder=".",
            id="field-workdir",
        )
        yield Static("[dim]Ctrl+S to save · Escape to cancel[/dim]", id="status-line")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#field-name", Input).focus()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_value(self, widget_id: str, default: str = "") -> str:
        try:
            return self.query_one(widget_id, Input).value.strip() or default
        except Exception:
            return default

    def _parse_schedule(self, raw: str) -> tuple[str, str]:
        """Parse raw schedule string into (schedule_type, schedule_value)."""
        raw = raw.strip()
        if not raw:
            return "interval", "1h"

        # Cron expression: 5 whitespace-separated tokens
        parts = raw.split()
        if len(parts) == 5:
            return "cron", raw

        # Map common shorthand
        _MAP = {
            "15m": ("interval", "15m"),
            "30m": ("interval", "30m"),
            "1h": ("hourly", "1h"),
            "2h": ("interval", "2h"),
            "6h": ("interval", "6h"),
            "12h": ("interval", "12h"),
            "24h": ("daily", "24h"),
            "1d": ("daily", "24h"),
        }
        if raw in _MAP:
            return _MAP[raw]

        return "interval", raw

    def _show_error(self, msg: str) -> None:
        try:
            self.query_one("#status-line", Static).update(f"[red]{msg}[/red]")
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_save_task(self) -> None:
        """Validate form and dismiss with task data."""
        name = self._get_value("#field-name")
        schedule_raw = self._get_value("#field-schedule", "1h")
        agent = self._get_value("#field-agent", "code-puppy")
        model = self._get_value("#field-model", "")
        prompt = self._get_value("#field-prompt")
        workdir = self._get_value("#field-workdir", ".")

        if not name:
            self._show_error("Task name is required.")
            self.query_one("#field-name", Input).focus()
            return

        if not prompt:
            self._show_error("Prompt is required.")
            self.query_one("#field-prompt", Input).focus()
            return

        schedule_type, schedule_value = self._parse_schedule(schedule_raw)

        self.dismiss(
            {
                "name": name,
                "prompt": prompt,
                "agent": agent,
                "model": model,
                "schedule_type": schedule_type,
                "schedule_value": schedule_value,
                "working_directory": workdir,
            }
        )
