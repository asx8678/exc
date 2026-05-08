"""Agent picker screen — browse and select agents.

Replaces code_puppy/command_line/agent_menu.py (653 lines).

Features:
- Scrollable + searchable left panel listing all agents
- Right panel showing selected agent's details (name, pinned model, description)
- Key bindings: Enter=select, P=pin model, C=clone, D=delete clone, Esc/Q=back
- No emoji sanitization needed — Textual/Rich handles them natively
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.agent_model_pinning import (
    apply_agent_pinned_model,
    get_effective_agent_pinned_model,
)
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_agent_entries() -> list[tuple[str, str, str]]:
    """Return sorted list of (agent_name, display_name, description)."""
    from code_puppy.agents import get_agent_descriptions, get_available_agents

    available = get_available_agents()
    descriptions = get_agent_descriptions()
    entries = [
        (name, display, descriptions.get(name, "No description available"))
        for name, display in available.items()
    ]
    entries.sort(key=lambda x: x[0].lower())
    return entries


def _get_pinned_model(agent_name: str) -> str | None:
    """Return the pinned model for *agent_name*.

    Uses the shared helper to ensure consistent behavior:
    - JSON agents: JSON `model` key takes precedence over config pin
    - Built-in agents: use config pin
    """
    return get_effective_agent_pinned_model(agent_name)


def _apply_pinned_model_and_reload(agent_name: str, model_choice: str) -> None:
    """Persist *model_choice* for *agent_name* and reload if current.

    Handles both built-in agents and JSON agents, ensuring stale config
    pins are cleared for JSON agents.
    """
    from code_puppy.agents import get_current_agent
    from code_puppy.messaging import emit_info, emit_warning

    try:
        pinned_model = apply_agent_pinned_model(agent_name, model_choice)
    except Exception as exc:
        emit_warning(f"Failed to apply pinned model: {exc}")
        return

    # Reload live agent if it's the active one
    current = get_current_agent()
    if current and current.name == agent_name:
        try:
            if hasattr(current, "refresh_config"):
                current.refresh_config()
            current.reload_code_generation_agent()
            if pinned_model:
                emit_info(f"Active agent reloaded with pinned model '{pinned_model}'")
            else:
                emit_info("Active agent reloaded with default model")
        except Exception as exc:
            emit_warning(f"Pinned model applied but reload failed: {exc}")


# ---------------------------------------------------------------------------
# AgentScreen
# ---------------------------------------------------------------------------


class AgentScreen(MenuScreen):
    """Full-screen agent picker — scrollable, searchable, with detail preview."""

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "select_agent", "Select", show=True),
        Binding("p", "pin_model", "Pin model", show=True),
        Binding("c", "clone_agent", "Clone", show=True),
        Binding("d", "delete_agent", "Delete clone", show=True),
    ]

    CSS = """
    AgentScreen {
        layout: vertical;
    }

    #agent-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    #agent-preview {
        height: 1fr;
        padding: 1 2;
        border-left: solid $primary-lighten-2;
    }

    SplitPanel {
        height: 1fr;
    }

    #agent-list {
        width: 35%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }
    """

    def __init__(self) -> None:
        super().__init__()
        self._entries: list[tuple[str, str, str]] = []
        self._current_agent_name: str = ""

    # --- Lifecycle ---

    def on_mount(self) -> None:
        """Load agents when screen is shown."""
        self._refresh_entries()
        self._populate_list()
        # Highlight the current agent by default
        self._focus_current_agent()

    def _refresh_entries(self) -> None:
        """Reload agent list from the agents module."""
        from code_puppy.agents import get_current_agent

        self._entries = _get_agent_entries()
        current = get_current_agent()
        self._current_agent_name = current.name if current else ""

    # --- Compose ---

    def compose(self) -> ComposeResult:
        yield Static(
            "🐶 Agent Picker — ↑↓ Navigate · Enter Select · P Pin · C Clone · D Delete",
            id="agent-title",
        )
        with SplitPanel():
            yield SearchableList(
                placeholder="🔍 Search agents…",
                id="agent-list",
                classes="split-panel--left",
            )
            yield RichLog(
                id="agent-preview",
                highlight=True,
                markup=True,
                classes="split-panel--right",
            )
        yield Footer()

    # --- Helpers ---

    def _populate_list(self, keep_filter: bool = False) -> None:
        """Fill the SearchableList with current entries."""
        agent_list = self.query_one("#agent-list", SearchableList)
        items = []
        for name, display_name, _desc in self._entries:
            badge_parts = []
            pinned = _get_pinned_model(name)
            if pinned:
                badge_parts.append(f"→ {pinned}")
            if name == self._current_agent_name:
                badge_parts.append("← current")
            badge = "  ".join(badge_parts)
            items.append(
                SearchableListItem(
                    label=display_name,
                    item_id=name,
                    badge=badge,
                )
            )
        agent_list.add_items(items)

    def _focus_current_agent(self) -> None:
        """Move ListView cursor to the current agent if it exists in the list."""
        from textual.widgets import ListView

        try:
            list_view = self.query_one("#search-list", ListView)
            for i, child in enumerate(list_view._nodes):  # type: ignore[attr-defined]
                if (
                    isinstance(child, SearchableListItem)
                    and child.item_id == self._current_agent_name
                ):
                    list_view.index = i
                    break
        except Exception:
            pass

    def _entry_for_id(self, item_id: str) -> tuple[str, str, str] | None:
        for entry in self._entries:
            if entry[0] == item_id:
                return entry
        return None

    def _show_preview(self, agent_name: str) -> None:
        """Update the right panel with details for the selected agent."""
        log = self.query_one("#agent-preview", RichLog)
        log.clear()

        entry = self._entry_for_id(agent_name)
        if entry is None:
            log.write("[dim]No agent selected.[/dim]")
            return

        name, display_name, description = entry
        pinned = _get_pinned_model(name)
        is_current = name == self._current_agent_name

        log.write("[bold cyan]AGENT DETAILS[/bold cyan]\n")
        log.write(f"[bold]Name:[/bold]         {name}")
        log.write(f"[bold]Display Name:[/bold] [cyan]{display_name}[/cyan]")
        log.write(
            "[bold]Pinned Model:[/bold] "
            + (f"[yellow]{pinned}[/yellow]" if pinned else "[dim]default[/dim]")
        )
        log.write(f"\n[bold]Description:[/bold]\n[dim]{description}[/dim]")
        log.write(
            "\n[bold]Status:[/bold] "
            + (
                "[green bold]✓ Currently Active[/green bold]"
                if is_current
                else "[dim]Not active[/dim]"
            )
        )

    # --- Message handlers ---

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Update preview when cursor moves."""
        self._show_preview(event.item.item_id)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Select the agent when Enter is pressed in the list."""
        self._do_select_agent(event.item.item_id)

    # --- Actions ---

    def action_select_agent(self) -> None:
        """Select the currently highlighted agent."""
        agent_list = self.query_one("#agent-list", SearchableList)
        item = agent_list.highlighted_item
        if item:
            self._do_select_agent(item.item_id)

    def _do_select_agent(self, agent_name: str) -> None:
        """Switch to the chosen agent and pop this screen."""
        from code_puppy.agents import get_available_agents, get_current_agent
        from code_puppy.messaging import emit_info, emit_warning

        available = get_available_agents()
        if agent_name not in available:
            emit_warning(f"Agent '{agent_name}' not found.")
            return

        # Only switch if it's different from current
        current = get_current_agent()
        if current and current.name == agent_name:
            emit_info(f"Already using agent '{agent_name}'.")
            self.dismiss(agent_name)
            return

        try:
            from code_puppy.agents import set_current_agent

            set_current_agent(agent_name)
            emit_info(f"Switched to agent '{agent_name}'.")
        except Exception as exc:
            emit_warning(f"Failed to switch agent: {exc}")

        self.dismiss(agent_name)

    def action_pin_model(self) -> None:
        """Show model picker to pin a model to the highlighted agent."""
        agent_list = self.query_one("#agent-list", SearchableList)
        item = agent_list.highlighted_item
        if not item:
            return

        agent_name = item.item_id

        async def _pick_and_pin() -> None:
            try:
                from code_puppy.command_line.model_picker_completion import (
                    load_model_names,
                )

                model_names = load_model_names() or []
            except Exception:
                model_names = []

            if not model_names:
                from code_puppy.messaging import emit_warning

                emit_warning("No models available to pin.")
                return

            pinned = _get_pinned_model(agent_name)

            from code_puppy.tui.screens.model_pin_screen import ModelPinScreen

            def _on_dismiss(model_choice: str | None) -> None:
                if model_choice:
                    _apply_pinned_model_and_reload(agent_name, model_choice)
                    # Refresh the list to show new badge
                    self._refresh_entries()
                    self._populate_list()
                    self._show_preview(agent_name)

            self.app.push_screen(
                ModelPinScreen(agent_name, model_names, pinned), _on_dismiss
            )

        self.app.call_later(_pick_and_pin)

    def action_clone_agent(self) -> None:
        """Clone the highlighted agent."""
        agent_list = self.query_one("#agent-list", SearchableList)
        item = agent_list.highlighted_item
        if not item:
            return

        agent_name = item.item_id
        try:
            from code_puppy.agents import clone_agent
            from code_puppy.messaging import emit_info, emit_warning

            cloned_name = clone_agent(agent_name)
            if cloned_name:
                emit_info(f"Cloned '{agent_name}' → '{cloned_name}'")
            else:
                emit_warning(f"Failed to clone '{agent_name}'")
        except Exception as exc:
            from code_puppy.messaging import emit_warning

            emit_warning(f"Clone error: {exc}")

        self._refresh_entries()
        self._populate_list()

    def action_delete_agent(self) -> None:
        """Delete a cloned agent."""
        agent_list = self.query_one("#agent-list", SearchableList)
        item = agent_list.highlighted_item
        if not item:
            return

        agent_name = item.item_id
        try:
            from code_puppy.agents import delete_clone_agent, is_clone_agent_name
            from code_puppy.messaging import emit_info, emit_warning

            if not is_clone_agent_name(agent_name):
                emit_warning("Only cloned agents can be deleted.")
                return
            if agent_name == self._current_agent_name:
                emit_warning(
                    "Cannot delete the active agent. Switch to another agent first."
                )
                return
            if delete_clone_agent(agent_name):
                emit_info(f"Deleted clone '{agent_name}'")
            else:
                emit_warning(f"Failed to delete '{agent_name}'")
        except Exception as exc:
            from code_puppy.messaging import emit_warning

            emit_warning(f"Delete error: {exc}")

        self._refresh_entries()
        self._populate_list()
