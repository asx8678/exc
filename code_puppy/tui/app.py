"""Main Textual application for Code Puppy.

This is the unified full-screen TUI that replaces the prompt_toolkit-based
interactive loop. It provides a chat-style interface with scrollable output,
an input line at the bottom, and a status bar showing token rate.
"""

import asyncio
import logging
import os
from collections import deque

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.reactive import reactive
from textual.widgets import Header, Input, RichLog

from code_puppy.tui.screens.add_model_screen import AddModelScreen

# Hoist all screen imports to module top level (Issue APP-L1)
# No circular import issues since screens don't import from app.py
from code_puppy.tui.screens.agent_screen import AgentScreen
from code_puppy.tui.screens.autosave_screen import AutosaveScreen
from code_puppy.tui.screens.colors_screen import ColorsScreen
from code_puppy.tui.screens.diff_screen import DiffScreen
from code_puppy.tui.screens.hooks_screen import HooksScreen
from code_puppy.tui.screens.mcp_form_screen import MCPFormScreen
from code_puppy.tui.screens.mcp_screen import MCPScreen
from code_puppy.tui.screens.model_screen import ModelScreen
from code_puppy.tui.screens.model_settings_screen import ModelSettingsScreen
from code_puppy.tui.screens.onboarding_screen import OnboardingScreen
from code_puppy.tui.screens.skills_screen import SkillsScreen
from code_puppy.tui.screens.uc_screen import UCScreen
from code_puppy.tui.theme import APP_CSS, CODE_PUPPY_THEME
from code_puppy.tui.widgets.completion_overlay import CompletionOverlay
from code_puppy.tui.widgets.info_bar import InfoBar

logger = logging.getLogger(__name__)

# Maximum number of history entries to keep
MAX_HISTORY = 500


class PuppyInput(Input):
    """Custom Input widget with command history support.

    Adds up/down arrow history navigation on top of Textual's Input.
    """

    DEFAULT_CSS = """
    PuppyInput {
        dock: bottom;
        height: 3;
        margin: 0 1;
        border: tall $primary-darken-2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(placeholder=">>> Type a message or /command...", **kwargs)
        self._history: deque[str] = deque(maxlen=MAX_HISTORY)
        self._history_index: int = -1
        self._saved_input: str = ""

    def add_to_history(self, text: str) -> None:
        """Add a command to history."""
        if text.strip() and (not self._history or self._history[-1] != text):
            self._history.append(text)
        self._history_index = -1
        self._saved_input = ""

    @property
    def _overlay(self) -> "CompletionOverlay | None":
        """Get the cached completion overlay from the app (Issue APP-M2)."""
        app = self.app
        if hasattr(app, "_completion_overlay"):
            return app._completion_overlay
        return None

    def _trigger_completions(self) -> None:
        """Show completions for the current input value."""
        from code_puppy.tui.completion import get_completions

        completions = get_completions(self.value, self.cursor_position)
        overlay = self._overlay
        if overlay is None:
            return
        if completions:
            overlay.show_completions(completions)
        else:
            overlay.hide_overlay()

    def on_key(self, event) -> None:
        """Handle up/down arrow for history and completion navigation."""
        overlay = self._overlay
        overlay_visible = overlay is not None and overlay.is_visible

        # When overlay is visible, forward navigation keys to it
        if overlay_visible:
            if event.key == "up":
                option_list = overlay.query_one("#completion-list")
                if option_list.highlighted is not None and option_list.highlighted > 0:
                    option_list.highlighted -= 1
                event.prevent_default()
                return
            elif event.key == "down":
                option_list = overlay.query_one("#completion-list")
                if option_list.highlighted is not None:
                    option_list.highlighted += 1
                event.prevent_default()
                return
            elif event.key == "tab" or event.key == "enter":
                # Accept the highlighted completion
                option_list = overlay.query_one("#completion-list")
                if option_list.highlighted is not None:
                    option_list.action_select()
                event.prevent_default()
                return
            elif event.key == "escape":
                overlay.hide_overlay()
                event.prevent_default()
                return

        # Normal history navigation (when overlay is NOT visible)
        if event.key == "up":
            if not self._history:
                return
            if self._history_index == -1:
                self._saved_input = self.value
                self._history_index = len(self._history) - 1
            elif self._history_index > 0:
                self._history_index -= 1
            self.value = self._history[self._history_index]
            self.cursor_position = len(self.value)
            event.prevent_default()
        elif event.key == "down":
            if self._history_index == -1:
                return
            if self._history_index < len(self._history) - 1:
                self._history_index += 1
                self.value = self._history[self._history_index]
            else:
                self._history_index = -1
                self.value = self._saved_input
            self.cursor_position = len(self.value)
            event.prevent_default()
        elif event.key == "tab":
            event.prevent_default()
            self._trigger_completions()


class CodePuppyApp(App):
    """The main Code Puppy TUI application.

    Layout:
        Header — app name, model, agent
        RichLog — scrollable chat output
        CompletionOverlay — tab-completion dropdown
        StatusBar — token rate, activity messages
        PuppyInput — command/message input
        Footer — F-key bindings
    """

    TITLE = "Code Puppy 🐶"

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.register_theme(CODE_PUPPY_THEME)
        self.theme = "code-puppy"

    CSS = (
        APP_CSS
        + """
    /* App-specific styles */
    #chat-log {
        height: 1fr;
        border-bottom: solid $primary-darken-1;
        scrollbar-gutter: stable;
        padding: 0 1;
    }
    """
    )

    BINDINGS = [
        Binding("f1", "show_help", "Help", show=True),
        Binding("f2", "show_model_picker", "Model", show=True),
        Binding("f3", "show_agent_picker", "Agent", show=True),
        Binding("f4", "show_settings", "Settings", show=True),
        Binding("ctrl+h", "show_help", "Help", show=False),  # Mac-friendly alt
        Binding("ctrl+x", "cancel_task", "Cancel", show=False),
    ]

    # Reactive properties
    is_working: reactive[bool] = reactive(False)
    token_rate: reactive[float] = reactive(0.0)
    status_message: reactive[str] = reactive("")

    def compose(self) -> ComposeResult:
        """Create the app layout."""
        yield Header()
        yield RichLog(id="chat-log", highlight=True, markup=True, wrap=True)
        yield CompletionOverlay(id="completions")
        yield PuppyInput(id="input")
        yield InfoBar(id="info-bar")

    def on_mount(self) -> None:
        """Initialize the app after mounting."""
        # Start the message bridge so emit_info/emit_warning/etc. appear in the TUI
        from code_puppy.tui.message_bridge import TUIMessageBridge

        self._message_bridge = TUIMessageBridge(self)
        self._message_bridge.start()

        # Cache DOM widget references to avoid repeated query_one calls (Issue APP-H1)
        self._chat_log = self.query_one("#chat-log", RichLog)
        self._input_widget = self.query_one("#input", PuppyInput)
        self._info_bar = self.query_one("#info-bar", InfoBar)
        self._completion_overlay = self.query_one("#completions", CompletionOverlay)

        self._chat_log.write("[bold cyan]🐶 Welcome to Code Puppy![/]")
        self._chat_log.write("")
        self._chat_log.write("[dim]Type a message or /command to get started.[/dim]")
        self._chat_log.write("[dim]Press F1 for help, Escape to quit.[/dim]")

        # Ensure slash commands are registered so completions work immediately
        try:
            import code_puppy.command_line.command_handler  # noqa: F401
        except Exception:
            pass
        self._chat_log.write("")
        self._input_widget.focus()

        # Initialize info bar with current agent and model
        self._info_bar.update_from_app_state()

        # Execute initial command if provided
        initial = getattr(self, "_initial_command", None)
        if initial:
            self._initial_command = None
            # Schedule it to run after the app is fully mounted
            self.call_later(self._run_initial_command, initial)

    def on_unmount(self) -> None:
        """Clean up resources when the app exits."""
        if hasattr(self, "_message_bridge"):
            self._message_bridge.stop()

    async def _run_initial_command(self, command: str) -> None:
        """Execute the initial command passed at startup."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        chat.write(f"\n[bold]Initial:[/bold] {command}")
        if command.startswith("/"):
            await self._handle_slash_command(command)
        else:
            await self._handle_agent_prompt(command)

    # --- Reactive watchers ---

    def watch_is_working(self, working: bool) -> None:
        """Update UI state when working status changes."""
        # Use cached widget reference (Issue APP-H1)
        try:
            input_widget = self._input_widget
        except AttributeError:
            input_widget = self.query_one("#input", PuppyInput)
        if working:
            input_widget.placeholder = ">>> (working... Ctrl+X to cancel)"
            input_widget.disabled = True
        else:
            input_widget.placeholder = ">>> Type a message or /command..."
            input_widget.disabled = False
            input_widget.focus()
        self._update_info_bar()

    def watch_token_rate(self, rate: float) -> None:
        """Update info bar with current token rate."""
        self._update_info_bar()

    def watch_status_message(self, message: str) -> None:
        """Update info bar text."""
        self._update_info_bar()

    def _update_info_bar(self) -> None:
        """Refresh the info bar status and token rate."""
        # Use cached widget reference (Issue APP-H1)
        try:
            bar = self._info_bar
        except AttributeError:
            try:
                bar = self.query_one("#info-bar", InfoBar)
            except Exception:
                return

        # Status text
        if self.is_working:
            if self.status_message:
                bar.status_text = f"⏳ {self.status_message}"
            else:
                bar.status_text = "⏳ Working..."
        else:
            bar.status_text = "Ready"

        # Token rate — always show when available
        if self.token_rate > 0:
            bar.rate_text = f"⚡ {self.token_rate:.1f} t/s"
        else:
            bar.rate_text = ""

        # Refresh agent/model in case they changed
        bar.update_from_app_state()

    def _on_screen_dismissed(self, _result=None) -> None:
        """Universal callback for any screen dismiss — refreshes the info bar."""
        # Use cached widget reference (Issue APP-H1)
        try:
            self._info_bar.update_from_app_state()
        except AttributeError:
            try:
                self.query_one("#info-bar", InfoBar).update_from_app_state()
            except Exception:
                pass
        except Exception:
            pass

    # --- Completion overlay handlers ---

    def on_completion_overlay_completion_selected(
        self, event: CompletionOverlay.CompletionSelected
    ) -> None:
        """Apply selected completion to input."""
        # Use cached widget reference (Issue APP-H1)
        input_widget = self._input_widget
        text = input_widget.value

        # For @ file completions, replace from the @ to cursor
        if "@" in text:
            at_pos = text.rfind("@")
            input_widget.value = text[: at_pos + 1] + event.item.text
        # For / commands, replace the whole input
        elif text.lstrip().startswith("/"):
            parts = text.split(None, 1)
            if len(parts) > 1 and event.item.text.startswith("/"):
                # Subcommand completion (e.g., /model name)
                input_widget.value = parts[0] + " " + event.item.text
            else:
                input_widget.value = event.item.text
        else:
            input_widget.value = event.item.text

        input_widget.cursor_position = len(input_widget.value)
        input_widget.focus()

    def on_completion_overlay_completion_dismissed(self, event) -> None:
        """Refocus input when completions dismissed."""
        # Use cached widget reference (Issue APP-H1)
        self._input_widget.focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        """Auto-show slash command completions as the user types."""
        if event.input.id != "input":
            return

        text = event.value.lstrip()
        # Use cached widget reference (Issue APP-H1)
        try:
            overlay = self._completion_overlay
        except AttributeError:
            try:
                overlay = self.query_one("#completions", CompletionOverlay)
            except Exception:
                return

        if text.startswith("/") or "@" in text:
            from code_puppy.tui.completion import get_completions

            completions = get_completions(event.value, len(event.value))
            if completions:
                overlay.show_completions(completions)
            else:
                overlay.hide_overlay()
        else:
            overlay.hide_overlay()

    # --- Input handling ---

    async def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle user input submission."""
        if event.input.id != "input":
            return

        # Hide completions overlay on submit (Issue APP-H1: use cached reference)
        try:
            self._completion_overlay.hide_overlay()
        except AttributeError:
            try:
                self.query_one("#completions", CompletionOverlay).hide_overlay()
            except Exception:
                pass
        except Exception:
            pass

        text = event.value.strip()
        if not text:
            return

        # Use cached widget references (Issue APP-H1)
        input_widget = self._input_widget
        input_widget.add_to_history(text)
        input_widget.value = ""

        chat = self._chat_log
        chat.write(f"\n[bold]You:[/bold] {text}")

        # Handle exit commands
        if text.lower() in ("/exit", "/quit", "exit", "quit"):
            self.exit()
            return

        # Handle /clear
        if text.lower() in ("/clear", "clear"):
            chat.clear()
            chat.write("[dim]Conversation cleared.[/dim]")
            return

        # Shell pass-through: !command
        if text.startswith("!") and len(text) > 1:
            await self._handle_shell_passthrough(text)
            return

        # Slash commands
        if text.startswith("/"):
            await self._handle_slash_command(text)
            return

        # Regular text → send to agent
        await self._handle_agent_prompt(text)

    # --- Slash command handlers (Issue APP-M1: dict dispatch) ---

    def _cmd_help(self, command: str, chat) -> None:
        """Handle /help, /h → render directly in chat."""
        try:
            from code_puppy.command_line.command_handler import get_commands_help

            help_text = get_commands_help()
            chat.write(help_text)
        except Exception as e:
            chat.write(f"[red]Error loading help: {e}[/red]")

    def _cmd_model(self, command: str, chat) -> None:
        """Handle /model, /m (no args) → Textual model picker."""
        self._show_model_picker_screen()

    def _cmd_agent(self, command: str, chat) -> None:
        """Handle /agent, /a (no args) → Textual agent picker."""

        def _on_agent_selected_cmd(_result=None) -> None:
            try:
                self._info_bar.update_from_app_state()
            except AttributeError:
                try:
                    self.query_one("#info-bar", InfoBar).update_from_app_state()
                except Exception:
                    pass
            except Exception:
                pass

        self.push_screen(AgentScreen(), callback=_on_agent_selected_cmd)

    def _cmd_settings(self, command: str, chat) -> None:
        """Handle /settings, /model_settings → Textual settings screen."""
        self.push_screen(ModelSettingsScreen(), callback=self._on_screen_dismissed)

    def _cmd_diff(self, command: str, chat) -> None:
        """Handle /diff → Textual diff screen."""
        self.push_screen(DiffScreen())

    def _cmd_colors(self, command: str, chat) -> None:
        """Handle /colors → Textual colors screen."""
        self.push_screen(ColorsScreen())

    def _cmd_tutorial(self, command: str, chat) -> None:
        """Handle /tutorial → Textual onboarding screen."""
        self.push_screen(OnboardingScreen())

    def _cmd_autosave_load(self, command: str, chat) -> None:
        """Handle /autosave_load → Textual autosave screen."""
        self.push_screen(AutosaveScreen())

    def _cmd_skills(self, command: str, chat) -> None:
        """Handle /skills, /skill → Textual skills screen."""
        self.push_screen(SkillsScreen())

    def _cmd_hooks(self, command: str, chat) -> None:
        """Handle /hooks, /hook → Textual hooks screen."""
        self.push_screen(HooksScreen())

    def _cmd_scheduler(self, command: str, chat) -> None:
        """Handle /scheduler, /sched, /cron → migrated to Elixir Oban backend."""
        chat.emit_info(
            "📅 The scheduler has been migrated to the Elixir Oban backend. Use the Elixir CLI."
        )

    def _cmd_uc(self, command: str, chat) -> None:
        """Handle /uc → Textual UC screen."""
        self.push_screen(UCScreen())

    def _cmd_add_model(self, command: str, chat) -> None:
        """Handle /add_model → Textual add model screen."""
        self.push_screen(AddModelScreen(), callback=self._on_screen_dismissed)

    # Dispatch table for slash commands (Issue APP-M1: dict dispatch)
    # Maps command names to handler methods
    _SLASH_COMMANDS: dict[str, str] = {
        "/help": "_cmd_help",
        "/h": "_cmd_help",
        "/model": "_cmd_model",
        "/m": "_cmd_model",
        "/agent": "_cmd_agent",
        "/a": "_cmd_agent",
        "/settings": "_cmd_settings",
        "/model_settings": "_cmd_settings",
        "/diff": "_cmd_diff",
        "/colors": "_cmd_colors",
        "/tutorial": "_cmd_tutorial",
        "/autosave_load": "_cmd_autosave_load",
        "/skills": "_cmd_skills",
        "/skill": "_cmd_skills",
        "/hooks": "_cmd_hooks",
        "/hook": "_cmd_hooks",
        "/scheduler": "_cmd_scheduler",
        "/sched": "_cmd_scheduler",
        "/cron": "_cmd_scheduler",
        "/uc": "_cmd_uc",
        "/add_model": "_cmd_add_model",
    }

    async def _handle_slash_command(self, command: str) -> None:
        """Dispatch a slash command to the command handler.

        IMPORTANT: Commands that launch interactive terminal pickers MUST be
        intercepted here and routed to Textual screen equivalents.  If they
        fall through to handle_command() they will try to read from stdin,
        which Textual owns → deadlock.

        Affected commands: /model, /m, /agent, /diff, /model_settings,
        /settings, /tutorial, /add_model, /colors, and several others.
        """
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        cmd_lower = command.strip().lower()
        cmd_parts = cmd_lower.split()
        cmd_name = cmd_parts[0] if cmd_parts else ""

        # ------------------------------------------------------------------ #
        # Commands routed to Textual screens (NEVER fall through to           #
        # handle_command — those use stdin pickers which deadlock in TUI).    #
        # ------------------------------------------------------------------ #

        # Dict dispatch for simple screen commands (Issue APP-M1)
        # Only dispatch if no additional args (args require fall-through)
        handler_name = self._SLASH_COMMANDS.get(cmd_name)
        if handler_name and len(cmd_parts) == 1:
            handler = getattr(self, handler_name)
            handler(command, chat)
            return

        # /mcp install → Textual MCP catalog screen
        _cmd_parts = command.strip().split()
        if (
            len(_cmd_parts) >= 2
            and _cmd_parts[0].lower() == "/mcp"
            and _cmd_parts[1].lower() == "install"
        ):

            def _on_mcp_selected(server_id: str | None) -> None:
                if server_id:
                    self._install_mcp_server(server_id)

            self.push_screen(MCPScreen(), callback=_on_mcp_selected)
            return

        # /mcp add → Textual MCP form screen
        if (
            len(_cmd_parts) >= 2
            and _cmd_parts[0].lower() == "/mcp"
            and _cmd_parts[1].lower() == "add"
        ):

            def _on_mcp_form_done(server_name: str | None) -> None:
                if server_name:
                    _chat = self._chat_log
                    _chat.write(
                        f"[bold green]✅ Custom MCP server '[cyan]{server_name}[/cyan]' added![/bold green]"
                    )
                    _chat.write(
                        f"[dim]Use '/mcp start {server_name}' to start it.[/dim]"
                    )

            self.push_screen(MCPFormScreen(), callback=_on_mcp_form_done)
            return

        # ------------------------------------------------------------------ #
        # Safe fall-through: commands that don't use interactive pickers.    #
        # ------------------------------------------------------------------ #
        try:
            from code_puppy.command_line.command_handler import handle_command

            # Run sync handle_command in thread pool to avoid blocking event loop (Issue APP-H2)
            result = await asyncio.to_thread(handle_command, command)

            if result is True:
                # Command handled — output was emitted via messaging system
                # The TUIMessageBridge will display it asynchronously
                # Yield control briefly to let the bridge process messages
                await asyncio.sleep(0)
            elif isinstance(result, str):
                # Command returned text to process as agent prompt
                await self._handle_agent_prompt(result)
            elif result is False:
                chat.write(f"[yellow]Unknown command: {command}[/yellow]")
                chat.write("[dim]Type /help for available commands.[/dim]")
        except Exception as e:
            chat.write(f"[red]Command error: {e}[/red]")

    async def _handle_agent_prompt(self, text: str) -> None:
        """Send text to the agent and stream the response."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        self.set_working(True, "Sending to agent...")

        try:
            from code_puppy.agents import get_current_agent
            from code_puppy.agents.event_stream_handler import set_streaming_console
            from code_puppy.config import (
                auto_save_session_if_enabled,
                save_command_to_history,
            )
            from code_puppy.prompt_runner import run_prompt_with_attachments
            from code_puppy.tui.message_bridge import TUIConsole

            save_command_to_history(text)

            agent = get_current_agent()

            # Redirect event_stream_handler output to the TUI chat log
            tui_console = TUIConsole(self)
            set_streaming_console(tui_console)

            result, agent_task = await run_prompt_with_attachments(
                agent, text, spinner_console=tui_console, use_spinner=False
            )

            if result is None:
                chat.write("[yellow]Task cancelled.[/yellow]")
                return

            # Display the final response as formatted markdown
            agent_response = result.output
            if agent_response:
                from rich.markdown import Markdown

                chat.write(Markdown(str(agent_response)))

            # Update message history for autosave
            if hasattr(result, "all_messages"):
                agent.set_message_history(list(result.all_messages()))

            auto_save_session_if_enabled()

        except asyncio.CancelledError:
            logger.debug("Task cancelled by user in TUI agent response")
            chat.write("[yellow]Task cancelled by user.[/yellow]")
        except Exception as e:
            chat.write(f"[red]Error: {e}[/red]")
            try:
                from code_puppy.error_logging import log_error

                log_error(e, context="TUI agent response error")
            except Exception:
                pass
        finally:
            self.set_working(False)

    async def _handle_shell_passthrough(self, text: str) -> None:
        """Handle !command shell passthrough."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        try:
            from code_puppy.command_line.shell_passthrough import (
                execute_shell_passthrough,
            )

            execute_shell_passthrough(text)
        except Exception as e:
            chat.write(f"[red]Shell error: {e}[/red]")

    # --- Action handlers for F-keys ---

    def action_show_help(self) -> None:
        """Show help information."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        chat.write("\n[bold cyan]━━━ Help ━━━[/bold cyan]")
        chat.write("[dim]F1[/dim] This help")
        chat.write("[dim]F2[/dim] Switch model")
        chat.write("[dim]F3[/dim] Switch agent")
        chat.write("[dim]F4[/dim] Model settings")
        chat.write("[dim]Ctrl+X[/dim] Cancel running task")
        chat.write("[dim]/exit[/dim] Quit")
        chat.write("")

    def action_show_model_picker(self) -> None:
        """Show model picker screen (F2)."""
        self._show_model_picker_screen()

    def _show_model_picker_screen(self) -> None:
        """Push the ModelScreen and activate the chosen model on return."""

        def _on_model_selected(model_name: str | None) -> None:
            if model_name:
                # Use cached widget references (Issue APP-H1)
                chat = self._chat_log
                chat.write(
                    f"[green]✅ Active model set: [bold]{model_name}[/bold][/green]"
                )
                # Refresh info bar to show new model
                try:
                    self._info_bar.update_from_app_state()
                except AttributeError:
                    try:
                        self.query_one("#info-bar", InfoBar).update_from_app_state()
                    except Exception:
                        pass
                except Exception:
                    pass

        self.push_screen(ModelScreen(), callback=_on_model_selected)

    def action_show_agent_picker(self) -> None:
        """Show agent picker screen."""

        def _on_agent_selected(_result=None) -> None:
            # Use cached widget reference (Issue APP-H1)
            try:
                self._info_bar.update_from_app_state()
            except AttributeError:
                try:
                    self.query_one("#info-bar", InfoBar).update_from_app_state()
                except Exception:
                    pass
            except Exception:
                pass

        self.push_screen(AgentScreen(), callback=_on_agent_selected)

    def action_show_settings(self) -> None:
        """Show model settings screen."""
        from code_puppy.tui.screens.model_settings_screen import ModelSettingsScreen

        self.push_screen(ModelSettingsScreen(), callback=self._on_screen_dismissed)

    def action_cancel_task(self) -> None:
        """Cancel the currently running task."""
        if self.is_working:
            # Cancel any running agent task
            if hasattr(self, "_current_agent_task") and self._current_agent_task:
                self._current_agent_task.cancel()
            self.is_working = False
            self.status_message = ""
            # Use cached widget reference (Issue APP-H1)
            chat = self._chat_log
            chat.write("[red]Task cancelled.[/red]")

    # --- MCP install helpers ---

    def _install_mcp_server(self, server_id: str) -> None:
        """Install a catalog MCP server with env-var defaults (no interactive prompt)."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        try:
            from code_puppy.mcp_.server_registry_catalog import catalog

            server = catalog.by_id.get(server_id)
        except Exception:
            server = None

        if server is None:
            chat.write(f"[red]Unknown MCP server: {server_id}[/red]")
            return

        # Build a minimal config using already-set env vars; skip interactive prompts
        env_vars = {}
        for var in server.get_environment_vars():
            val = os.environ.get(var, "")
            if val:
                env_vars[var] = val

        install_config = {
            "name": server.name,
            "env_vars": env_vars,
            "cmd_args": {},
        }

        chat.write(f"[bold]⏳ Installing [cyan]{server.display_name}[/cyan]...[/bold]")

        def _do_install() -> None:
            try:
                from code_puppy.command_line.mcp.catalog_server_installer import (
                    install_catalog_server,
                )
                from code_puppy.mcp_.manager import get_manager

                manager = get_manager()
                success = install_catalog_server(manager, server, install_config)
                self.app.call_from_thread(
                    self._on_mcp_install_done, server.display_name, success
                )
            except Exception as exc:
                self.app.call_from_thread(
                    self._on_mcp_install_done, server.display_name, False, str(exc)
                )

        self.run_worker(_do_install, thread=True)

    def _on_mcp_install_done(
        self, display_name: str, success: bool, error: str | None = None
    ) -> None:
        """Report MCP install result to the chat log."""
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        if success:
            chat.write(
                f"[bold green]✅ '{display_name}' installed successfully![/bold green]"
            )
        else:
            msg = error or "Installation failed."
            chat.write(f"[bold red]❌ Install failed: {msg}[/bold red]")

    # --- Public API for other modules to write to the chat ---

    def write_to_chat(self, content: str, **kwargs) -> None:
        """Write content to the chat log.

        This is the primary API for other modules (stream renderer,
        command handler, etc.) to output to the chat.
        """
        # Use cached widget reference (Issue APP-H1)
        chat = self._chat_log
        chat.write(content, **kwargs)

    def set_working(self, working: bool, message: str = "") -> None:
        """Set the working state and optional status message."""
        self.is_working = working
        self.status_message = message

    def update_token_rate(self, rate: float) -> None:
        """Update the displayed token rate."""
        self.token_rate = rate


def run_app() -> None:
    """Entry point to launch the Code Puppy TUI.

    Can be called from main.py or used for standalone testing.
    """
    app = CodePuppyApp()
    app.run()


if __name__ == "__main__":
    run_app()
