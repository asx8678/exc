"""Custom MCP server form screen — Textual replacement for custom_server_form.py.

Provides a single-screen form for configuring a custom MCP server:
  ● Server name  (Input)
  ● Server type  (ListView: stdio / http / sse)
  ● JSON config  (TextArea with placeholder)
  ● Submit: Ctrl+S saves and dismisses with (name, type, config_dict)

Wired via: /mcp add → app.py pushes MCPFormScreen
"""

import json
import os
import re

from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import (
    Button,
    Footer,
    Input,
    Label,
    ListItem,
    ListView,
    Static,
    TextArea,
)

from code_puppy.tui.base_screen import MenuScreen

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SERVER_TYPES = ["stdio", "http", "sse"]

SERVER_TYPE_DESCRIPTIONS: dict[str, str] = {
    "stdio": "📟 Local command (npx, python, uvx) via stdin/stdout",
    "http": "🌐 HTTP endpoint implementing MCP protocol",
    "sse": "📡 Server-Sent Events for real-time streaming",
}

_EXAMPLES: dict[str, str] = {
    "stdio": """{
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
  "env": {
    "NODE_ENV": "production"
  },
  "timeout": 30
}""",
    "http": """{
  "url": "http://localhost:8080/mcp",
  "headers": {
    "Authorization": "Bearer $MY_API_KEY",
    "Content-Type": "application/json"
  },
  "timeout": 30
}""",
    "sse": """{
  "url": "http://localhost:8080/sse",
  "headers": {
    "Authorization": "Bearer $MY_API_KEY"
  }
}""",
}

_NAME_PATTERN = r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_name(name: str) -> str | None:
    """Return an error message if *name* is invalid, else None."""
    name = name.strip()
    if not name:
        return "Server name is required."
    if not re.match(_NAME_PATTERN, name):
        return (
            "Name must start with alphanumeric; only letters, digits, - and _ allowed."
        )
    if len(name) > 64:
        return "Name too long (max 64 characters)."
    return None


def _validate_json(text: str, server_type: str) -> str | None:
    """Return an error message if the JSON config is invalid, else None."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        return f"Invalid JSON: {exc.msg} (line {exc.lineno})"

    if server_type == "stdio" and "command" not in data:
        return 'Missing required field: "command"'
    if server_type in ("http", "sse") and "url" not in data:
        return 'Missing required field: "url"'
    return None


def _save_server(name: str, server_type: str, config: dict) -> str | None:
    """Register the server with the MCP manager and persist to disk.

    Returns None on success, or an error string on failure.
    """
    try:
        from code_puppy.config import MCP_SERVERS_FILE
        from code_puppy.mcp_.managed_server import ServerConfig
        from code_puppy.mcp_.manager import get_manager

        manager = get_manager()

        server_config = ServerConfig(
            id=name,
            name=name,
            type=server_type,
            enabled=True,
            config=config,
        )
        server_id = manager.register_server(server_config)
        if not server_id:
            return "Failed to register server (name may already exist)."

        # Persist to mcp_servers.json
        if os.path.exists(MCP_SERVERS_FILE):
            with open(MCP_SERVERS_FILE) as fh:
                data = json.load(fh)
        else:
            data = {}
        servers = data.setdefault("mcp_servers", {})
        save_cfg = dict(config)
        save_cfg["type"] = server_type
        servers[name] = save_cfg
        os.makedirs(os.path.dirname(MCP_SERVERS_FILE), exist_ok=True)
        with open(MCP_SERVERS_FILE, "w") as fh:
            json.dump(data, fh, indent=2)

        return None  # success
    except Exception as exc:
        return str(exc)


# ---------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------


class MCPFormScreen(MenuScreen):
    """Custom MCP server configuration form.

    Fields:
      • Name   — Input widget (single-line)
      • Type   — ListView of stdio / http / sse
      • Config — TextArea for JSON (Ctrl+N loads example for current type)

    Ctrl+S validates and saves; the screen is dismissed with the server name
    on success so the caller knows a new server was registered.
    Escape cancels without saving.
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("ctrl+s", "save", "Save", show=True),
        Binding("ctrl+n", "load_example", "Example", show=True),
    ]

    DEFAULT_CSS = """
    MCPFormScreen {
        layers: default;
    }
    MCPFormScreen > #form-title {
        dock: top;
        height: 3;
        background: $primary-darken-2;
        color: $text;
        text-align: center;
        padding: 1;
        text-style: bold;
    }
    MCPFormScreen > #form-body {
        height: 1fr;
        padding: 1 2;
        overflow-y: auto;
    }
    MCPFormScreen .field-label {
        color: $secondary;
        text-style: bold;
        margin-top: 1;
    }
    MCPFormScreen .field-hint {
        color: $text-muted;
        margin-bottom: 0;
    }
    MCPFormScreen #type-list {
        height: 5;
        margin-bottom: 1;
    }
    MCPFormScreen #json-area {
        height: 12;
        margin-bottom: 1;
    }
    MCPFormScreen #error-label {
        color: $error;
        margin-top: 1;
    }
    MCPFormScreen #success-label {
        color: $success;
        margin-top: 1;
    }
    MCPFormScreen #save-btn {
        margin-top: 1;
        width: 20;
    }
    """

    def __init__(
        self,
        *,
        edit_mode: bool = False,
        existing_name: str = "",
        existing_type: str = "stdio",
        existing_config: dict | None = None,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self._edit_mode = edit_mode
        self._existing_name = existing_name
        self._initial_type = existing_type if existing_type in SERVER_TYPES else "stdio"
        self._initial_config = existing_config

    # ------------------------------------------------------------------
    # Compose
    # ------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        title = "✏️  Edit MCP Server" if self._edit_mode else "➕  Add Custom MCP Server"
        yield Static(title, id="form-title")

        with Static(id="form-body"):
            # --- Name ---
            yield Label("1. Server Name", classes="field-label")
            yield Label(
                "Alphanumeric, hyphens and underscores OK (max 64 chars).",
                classes="field-hint",
            )
            yield Input(
                value=self._existing_name,
                placeholder="my-mcp-server",
                id="name-input",
            )

            # --- Type ---
            yield Label("2. Server Type", classes="field-label")
            yield ListView(id="type-list")

            # --- JSON Config ---
            yield Label("3. JSON Configuration", classes="field-label")
            yield Label(
                "Ctrl+N loads an example for the selected type.",
                classes="field-hint",
            )
            initial_json = (
                json.dumps(self._initial_config, indent=2)
                if self._initial_config
                else _EXAMPLES[self._initial_type]
            )
            yield TextArea(initial_json, id="json-area", language="json")

            # --- Status ---
            yield Static("", id="error-label")
            yield Static("", id="success-label")

            # --- Submit ---
            yield Button("Save & Install  (Ctrl+S)", id="save-btn", variant="success")

        yield Footer()

    # ------------------------------------------------------------------
    # Mount
    # ------------------------------------------------------------------

    def on_mount(self) -> None:
        """Populate the type list and focus the name input."""
        lv = self.query_one("#type-list", ListView)
        for t in SERVER_TYPES:
            desc = SERVER_TYPE_DESCRIPTIONS.get(t, t)
            lv.append(ListItem(Label(desc), id=f"type-{t}"))

        # Highlight the initial type
        try:
            idx = SERVER_TYPES.index(self._initial_type)
            lv.move_cursor(row=idx)
        except ValueError:
            pass

        self.query_one("#name-input", Input).focus()

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_save(self) -> None:
        """Validate and save the server; dismiss on success."""
        self._do_save()

    def action_load_example(self) -> None:
        """Load the JSON example for the currently selected type."""
        server_type = self._current_type()
        ta = self.query_one("#json-area", TextArea)
        ta.load_text(_EXAMPLES[server_type])
        self._set_error("")
        self._set_success(f"Loaded example for '{server_type}'.")

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "save-btn":
            self._do_save()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _current_type(self) -> str:
        """Return the server type selected in the ListView."""
        lv = self.query_one("#type-list", ListView)
        if lv.highlighted_child is not None:
            item_id: str = lv.highlighted_child.id or ""
            if item_id.startswith("type-"):
                return item_id[len("type-") :]
        return SERVER_TYPES[0]

    def _set_error(self, msg: str) -> None:
        self.query_one("#error-label", Static).update(
            f"[bold red]❌ {msg}[/bold red]" if msg else ""
        )

    def _set_success(self, msg: str) -> None:
        self.query_one("#success-label", Static).update(
            f"[bold green]✅ {msg}[/bold green]" if msg else ""
        )

    def _do_save(self) -> None:
        """Validate inputs, save server, dismiss on success."""
        self._set_error("")
        self._set_success("")

        name = self.query_one("#name-input", Input).value.strip()
        server_type = self._current_type()
        json_text = self.query_one("#json-area", TextArea).text.strip()

        # --- Validate name ---
        name_err = _validate_name(name)
        if name_err:
            self._set_error(name_err)
            self.query_one("#name-input", Input).focus()
            return

        # --- Validate JSON ---
        json_err = _validate_json(json_text, server_type)
        if json_err:
            self._set_error(json_err)
            self.query_one("#json-area", TextArea).focus()
            return

        config = json.loads(json_text)

        # --- Persist ---
        err = _save_server(name, server_type, config)
        if err:
            self._set_error(err)
            return

        self._set_success(f"Server '{name}' saved!")
        # Dismiss with the new server name so the caller knows it succeeded
        self.dismiss(name)
