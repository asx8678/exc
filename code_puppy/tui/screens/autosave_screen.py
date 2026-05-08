"""Autosave session browser — Textual replacement for autosave_menu.py.

Two-panel layout:
  Left  — searchable list of sessions sorted by timestamp (most recent first)
  Right — session metadata + last message preview (Rich-rendered)

Enter loads the highlighted session. Escape cancels.
"""

import json
from datetime import datetime
from pathlib import Path

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, RichLog, Static

from code_puppy.config import AUTOSAVE_DIR
from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem
from code_puppy.tui.widgets.split_panel import SplitPanel

# ---------------------------------------------------------------------------
# Data helpers (thin wrappers around session_storage)
# ---------------------------------------------------------------------------


def _get_session_metadata(base_dir: Path, session_name: str) -> dict:
    """Load the JSON metadata file for a session."""
    meta_path = base_dir / f"{session_name}_meta.json"
    try:
        with meta_path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def _get_session_entries(base_dir: Path) -> list[tuple[str, dict]]:
    """Return all sessions sorted by timestamp (most recent first)."""
    from code_puppy.session_storage import list_sessions

    try:
        sessions = list_sessions(base_dir)
    except FileNotFoundError, PermissionError:
        return []

    entries: list[tuple[str, dict]] = []
    for name in sessions:
        try:
            metadata = _get_session_metadata(base_dir, name)
        except Exception:
            metadata = {}
        entries.append((name, metadata))

    def _sort_key(entry: tuple[str, dict]) -> datetime:
        ts = entry[1].get("timestamp")
        if ts:
            try:
                return datetime.fromisoformat(ts)
            except ValueError:
                pass
        return datetime.min

    entries.sort(key=_sort_key, reverse=True)
    return entries


def _extract_last_user_message(history: list) -> str:
    """Return the text of the most recent user message from history."""
    for msg in reversed(history):
        parts: list[str] = []
        for part in msg.parts:
            if hasattr(part, "content"):
                content = part.content
                if isinstance(content, str) and content.strip():
                    parts.append(content)
        if parts:
            return "\n\n".join(parts)
    return "[No messages found]"


# ---------------------------------------------------------------------------
# AutosaveScreen
# ---------------------------------------------------------------------------


class AutosaveScreen(MenuScreen):
    """Textual Screen for browsing and loading autosave sessions.

    Replaces code_puppy/command_line/autosave_menu.py.

    Bindings:
        Enter  — load the highlighted session and return to chat
        Escape — cancel (no load)
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "load_session", "Load Session", show=True),
    ]

    CSS = """
    AutosaveScreen {
        layout: vertical;
    }

    #autosave-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    SplitPanel {
        height: 1fr;
    }

    #session-list {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }

    #session-preview {
        height: 1fr;
        padding: 1 2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._base_dir = Path(AUTOSAVE_DIR)
        self._entries: list[tuple[str, dict]] = []

    def compose(self) -> ComposeResult:
        yield Static(
            "💾 Autosave Session Browser — ↑↓ Navigate · Enter Load",
            id="autosave-title",
        )
        with SplitPanel(left_title="Sessions", right_title="Preview"):
            yield SearchableList(
                placeholder="🔍 Search sessions...",
                id="session-list",
                classes="split-panel--left",
            )
            yield RichLog(
                id="session-preview",
                highlight=True,
                markup=True,
                classes="split-panel--right",
            )
        yield Footer()

    def on_mount(self) -> None:
        """Load sessions and populate the list after mounting."""
        self._entries = _get_session_entries(self._base_dir)
        self._populate_list()
        self.query_one("#session-list", SearchableList).focus()

    # --- Internal helpers --------------------------------------------------

    def _populate_list(self) -> None:
        """Fill the SearchableList with session entries."""
        session_list = self.query_one("#session-list", SearchableList)
        items: list[SearchableListItem] = []
        for name, meta in self._entries:
            ts = meta.get("timestamp", "")
            try:
                dt = datetime.fromisoformat(ts)
                time_str = dt.strftime("%m-%d %H:%M")
            except Exception:
                time_str = "??-?? ??:??"
            msg_count = meta.get("message_count", "?")
            badge = f"{time_str} · {msg_count}msg"
            items.append(SearchableListItem(label=name, item_id=name, badge=badge))
        if not items:
            items.append(
                SearchableListItem(
                    label="[No autosave sessions found]",
                    item_id="",
                    disabled=True,
                )
            )
        session_list.add_items(items)

    def _show_preview(self, session_name: str) -> None:
        """Update the right panel with session details and last message."""
        from code_puppy.session_storage import load_session

        log = self.query_one("#session-preview", RichLog)
        log.clear()

        meta = next((m for n, m in self._entries if n == session_name), {})

        ts = meta.get("timestamp", "unknown")
        try:
            dt = datetime.fromisoformat(ts)
            time_str = dt.strftime("%Y-%m-%d %H:%M:%S")
        except Exception:
            time_str = ts

        msg_count = meta.get("message_count", 0)
        tokens = meta.get("total_tokens", 0)

        log.write("[bold cyan]SESSION DETAILS[/bold cyan]\n")
        log.write(f"[bold]Name:[/bold]     {session_name}")
        log.write(f"[bold]Saved:[/bold]    [dim]{time_str}[/dim]")
        log.write(f"[bold]Messages:[/bold] {msg_count}")
        log.write(f"[bold]Tokens:[/bold]   {tokens:,}\n")
        log.write("[bold]Last Message Preview:[/bold]")

        try:
            history = load_session(session_name, self._base_dir)
            last = _extract_last_user_message(history)
            if len(last) > 600:
                last = last[:600] + "…"
            log.write(f"[dim]{last}[/dim]")
        except Exception as exc:
            log.write(f"[red]Error loading preview: {exc}[/red]")

    # --- Event handlers ----------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Refresh preview when cursor moves to a new session."""
        if event.item.item_id:
            self._show_preview(event.item.item_id)

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Load session when Enter is pressed in the list."""
        if event.item.item_id:
            self._do_load_session(event.item.item_id)

    # --- Actions -----------------------------------------------------------

    def action_load_session(self) -> None:
        """Load the currently highlighted session."""
        session_list = self.query_one("#session-list", SearchableList)
        item = session_list.highlighted_item
        if item and item.item_id:
            self._do_load_session(item.item_id)

    def _do_load_session(self, session_name: str) -> None:
        """Load session into the current agent and close the screen."""
        from code_puppy.messaging import emit_success, emit_warning
        from code_puppy.session_storage import load_session_with_hashes

        try:
            history, compacted_hashes = load_session_with_hashes(
                session_name, self._base_dir
            )
            from code_puppy.agents import get_current_agent

            agent = get_current_agent()
            agent.set_message_history(history)
            agent.restore_compacted_hashes(compacted_hashes)

            try:
                from code_puppy.config import set_current_autosave_from_session_name

                set_current_autosave_from_session_name(session_name)
            except Exception:
                pass

            emit_success(f"✅ Session loaded: {session_name} ({len(history)} messages)")

            try:
                from code_puppy.command_line.autosave_menu import (
                    display_resumed_history,
                )

                display_resumed_history(history)
            except Exception:
                pass

        except Exception as exc:
            emit_warning(f"Failed to load session '{session_name}': {exc}")

        self.app.pop_screen()
