"""Info bar widget — replaces both StatusBar and Footer.

Shows current agent, model, and token rate in a single
bottom-docked bar with live updates.
"""

from textual.app import ComposeResult
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Static


class InfoBar(Widget):
    """Single-line bottom bar showing current agent, model, and performance."""

    DEFAULT_CSS = """
    InfoBar {
        dock: bottom;
        height: 1;
        background: $primary-background;
        color: $text;
        layout: horizontal;
    }

    InfoBar > .info-bar--agent {
        width: auto;
        padding: 0 1;
        color: $success;
        text-style: bold;
    }

    InfoBar > .info-bar--sep {
        width: 3;
        color: $text-muted;
        content-align: center middle;
    }

    InfoBar > .info-bar--model {
        width: auto;
        padding: 0 1;
        color: $accent;
    }

    InfoBar > .info-bar--status {
        width: 1fr;
        padding: 0 1;
        color: $text-muted;
    }

    InfoBar > .info-bar--rate {
        width: auto;
        padding: 0 1;
        color: $warning;
    }
    """

    # Reactive properties that trigger refresh
    agent_name: reactive[str] = reactive("", layout=True)
    model_name: reactive[str] = reactive("", layout=True)
    status_text: reactive[str] = reactive("Ready", layout=True)
    rate_text: reactive[str] = reactive("", layout=True)

    def compose(self) -> ComposeResult:
        yield Static("", classes="info-bar--agent", id="ib-agent")
        yield Static(" │ ", classes="info-bar--sep")
        yield Static("", classes="info-bar--model", id="ib-model")
        yield Static(" │ ", classes="info-bar--sep")
        yield Static("", classes="info-bar--status", id="ib-status")
        yield Static("", classes="info-bar--rate", id="ib-rate")

    def _refresh_agent(self) -> None:
        """Update the agent label."""
        try:
            label = self.query_one("#ib-agent", Static)
            label.update(f"🐶 {self.agent_name}" if self.agent_name else "🐶 —")
        except Exception:
            pass

    def _refresh_model(self) -> None:
        """Update the model label."""
        try:
            label = self.query_one("#ib-model", Static)
            label.update(f"🤖 {self.model_name}" if self.model_name else "🤖 —")
        except Exception:
            pass

    def _refresh_status(self) -> None:
        """Update the status label."""
        try:
            label = self.query_one("#ib-status", Static)
            label.update(self.status_text)
        except Exception:
            pass

    def _refresh_rate(self) -> None:
        """Update the token rate label."""
        try:
            label = self.query_one("#ib-rate", Static)
            label.update(self.rate_text)
        except Exception:
            pass

    def watch_agent_name(self, value: str) -> None:
        self._refresh_agent()

    def watch_model_name(self, value: str) -> None:
        self._refresh_model()

    def watch_status_text(self, value: str) -> None:
        self._refresh_status()

    def watch_rate_text(self, value: str) -> None:
        self._refresh_rate()

    def update_from_app_state(self) -> None:
        """Pull current agent/model from app state. Call on mount and after changes."""
        try:
            from code_puppy.agents import get_current_agent

            agent = get_current_agent()
            self.agent_name = agent.display_name
        except Exception:
            self.agent_name = ""

        try:
            from code_puppy.command_line.model_picker_completion import get_active_model

            self.model_name = get_active_model() or ""
        except Exception:
            self.model_name = ""
