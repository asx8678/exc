"""Bridge between Code Puppy's messaging system and the Textual TUI.

Two components live here:

TUIMessageBridge
    Listens to the global MessageQueue and forwards messages to the
    Textual app's RichLog widget.  This replaces SynchronousInteractiveRenderer
    for TUI mode so that emit_info / emit_warning / etc. produce visible output.

TUIConsole
    A drop-in replacement for a Rich Console that redirects console.print()
    and console.file.write() calls into the RichLog widget.  Passed to
    set_streaming_console() so event_stream_handler writes to the TUI.
"""

import asyncio
import logging
import re
from typing import TYPE_CHECKING, Any

# OPTIMIZATION: Eager imports for high-frequency TUI callbacks
# These are imported at module load to avoid per-message import overhead
from rich.markdown import Markdown
from rich.text import Text

if TYPE_CHECKING:
    from code_puppy.tui.app import CodePuppyApp

    # Import MessageType at type-check time only (actual import done eagerly in functions)

logger = logging.getLogger(__name__)

# Regex for stripping ANSI escape codes produced by Rich / other renderers
# Matches: SGR sequences (colors/styles), cursor movement, OSC sequences,
# DECSET/DECRST sequences, and other CSI sequences
_ANSI_RE = re.compile(
    r"\x1b(?:"
    r"\[[0-9;]*[a-zA-Z]"  # CSI sequences (SGR, cursor, etc.)
    r"|\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC sequences (title, etc.)
    r"|\[\?[0-9;]*[hl]"  # DECSET/DECRST sequences
    r")"
)

# Sentinel object to mark message types that need Markdown rendering
_MARKDOWN_SENTINEL = object()

# Module-scope template dict for plain string styles (types not in this dict
# fall through to direct chat.write(content_str))
# Use _MARKDOWN_SENTINEL for types that need Markdown rendering instead of plain text
_PLAIN_STYLES: dict[str, str | object] = {
    "ERROR": "[red]❌ {content}[/red]",
    "WARNING": "[yellow]⚠ {content}[/yellow]",
    "SUCCESS": "[green]✅ {content}[/green]",
    "SYSTEM": "[dim]{content}[/dim]",
    "TOOL_OUTPUT": "[cyan]{content}[/cyan]",
    "HUMAN_INPUT_REQUEST": "[bold cyan]{content}[/bold cyan]",
    "AGENT_RESPONSE": _MARKDOWN_SENTINEL,  # Special: render as Markdown
}


def _strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from *text*."""
    return _ANSI_RE.sub("", text)


# ---------------------------------------------------------------------------
# TUIMessageBridge
# ---------------------------------------------------------------------------


class TUIMessageBridge:
    """Reads messages from the global MessageQueue and writes to Textual RichLog.

    This replaces SynchronousInteractiveRenderer for TUI mode.  Call
    ``start()`` once the Textual app is mounted; call ``stop()`` on unmount.
    """

    def __init__(self, app: "CodePuppyApp") -> None:
        self.app = app
        self._running = False
        self._task: asyncio.Task | None = None
        self._stop_event: asyncio.Event | None = None
        # Cached chat log widget reference to avoid query_one() per message
        self._chat_log: Any | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the bridge as an asyncio task (must be called from the event loop)."""
        if self._running:
            return
        self._running = True
        self._stop_event = asyncio.Event()
        self._task = asyncio.create_task(self._run())

        # Cache the chat log widget reference to avoid query_one() per message
        try:
            self._chat_log = self.app.query_one("#chat-log")
        except Exception:
            self._chat_log = None  # Widget not yet mounted, will retry on first message

        # Subscribe to the structured MessageBus as well
        try:
            from code_puppy.messaging import get_message_bus

            get_message_bus().subscribe(self._on_bus_message)
        except Exception:
            pass  # Bus not available — non-fatal

    def stop(self) -> None:
        """Stop the bridge and clean up."""
        self._running = False
        if self._stop_event:
            self._stop_event.set()

        # Drain queue before cancelling to avoid dropping in-flight messages
        try:
            from code_puppy.messaging import get_global_queue

            queue = get_global_queue()
            # Wait for queue to drain with a short timeout (max 2 seconds)
            queue.wait_for_empty(timeout=2.0)
        except Exception:
            pass  # Queue not available or error — continue with shutdown

        if self._task:
            self._task.cancel()
            self._task = None

        try:
            from code_puppy.messaging import get_message_bus

            get_message_bus().unsubscribe(self._on_bus_message)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Async lifecycle task
    # ------------------------------------------------------------------

    async def _run(self) -> None:
        """Register as listener, flush startup buffer, then keep running."""
        from code_puppy.messaging import get_global_queue

        queue = get_global_queue()
        queue.start()  # Start the background thread that dispatches to listeners

        # Register listener *before* mark_renderer_active so messages that
        # arrive between the two calls are not dropped.
        queue.add_listener(self._on_queue_message_from_thread)
        queue.mark_renderer_active()

        # Flush messages that were buffered before any renderer was active.
        # get_buffered_messages() uses swap-and-clear, so the buffer is drained atomically.
        buffered = queue.get_buffered_messages()
        for msg in buffered:
            self._render_queue_message(msg)

        try:
            # Wait for the stop signal instead of polling.
            if self._stop_event:
                await self._stop_event.wait()
        except asyncio.CancelledError:
            pass
        finally:
            queue.remove_listener(self._on_queue_message_from_thread)
            queue.mark_renderer_inactive()
            queue.stop()

    # ------------------------------------------------------------------
    # MessageQueue callbacks
    # ------------------------------------------------------------------

    def _on_queue_message_from_thread(self, message) -> None:
        """Called from the MessageQueue background thread — schedule on event loop."""
        try:
            self.app.call_from_thread(self._render_queue_message, message)
        except Exception:
            # App may be shutting down
            pass

    def _render_queue_message(self, message) -> None:
        """Render a UIMessage to the chat log (must run on Textual thread)."""
        # Use cached chat log reference, or fetch and cache on first use
        chat = self._chat_log
        if chat is None:
            try:
                chat = self.app.query_one("#chat-log")
                self._chat_log = chat
            except Exception:
                return  # Widget not yet mounted

        content = message.content
        msg_type = message.type

        # Rich renderables are passed straight to RichLog
        if hasattr(content, "__rich__") or hasattr(content, "__rich_console__"):
            chat.write(content)
            return

        content_str = str(content) if content is not None else ""
        if not content_str:
            return

        # Map message type → styled output using dict lookup (faster than if/elif chain)
        template = _PLAIN_STYLES.get(msg_type.name)
        if template is _MARKDOWN_SENTINEL:
            # AGENT_RESPONSE: render as Markdown with fallback to plain text
            try:
                chat.write(Markdown(content_str))
            except Exception:
                chat.write(content_str)
        elif template:
            chat.write(template.format(content=content_str))
        else:
            # INFO, DEBUG, DIVIDER, PLANNED_NEXT_STEPS, etc.
            chat.write(content_str)

    # ------------------------------------------------------------------
    # MessageBus callbacks (structured messages)
    # ------------------------------------------------------------------

    def _on_bus_message(self, message) -> None:
        """Handle structured messages from the MessageBus."""
        try:
            from code_puppy.messaging.messages import AgentResponseMessage

            if isinstance(message, AgentResponseMessage):
                # Schedule on the Textual event loop
                self.app.call_from_thread(self._render_agent_response, message)
        except Exception:
            pass

    def _render_agent_response(self, message) -> None:
        """Render an AgentResponseMessage to the chat log."""
        # Use cached chat log reference, or fetch and cache on first use
        chat = self._chat_log
        if chat is None:
            try:
                chat = self.app.query_one("#chat-log")
                self._chat_log = chat
            except Exception:
                return

        if not message.content:
            return

        content = str(message.content)
        if message.is_markdown:
            try:
                chat.write(Markdown(content))
                return
            except Exception:
                pass
        chat.write(content)


# ---------------------------------------------------------------------------
# TUIConsole
# ---------------------------------------------------------------------------


class TUIConsole:
    """A console-like object that redirects output to the Textual RichLog.

    Passed to ``set_streaming_console()`` so that ``event_stream_handler``
    writes streaming tokens / banners to the TUI chat log instead of stdout.

    We also set ``self.file = self`` so that any code using
    ``console.file.write()`` writes here via ``TUIConsole.write()``.
    """

    def __init__(self, app: "CodePuppyApp") -> None:
        self.app = app
        # Rich and other tools may use ``console.file`` for low-level writes
        self.file = self
        self._width: int = 120

    @property
    def width(self) -> int:
        """Return a sensible column width for renderers that need it."""
        return self._width

    # ------------------------------------------------------------------
    # Rich Console API (used by event_stream_handler directly)
    # ------------------------------------------------------------------

    def print(self, *args, **kwargs) -> None:
        """Emulate ``Rich.Console.print()`` → write each arg to the chat log."""
        # Use cached chat log reference from bridge
        chat = (
            self.app._message_bridge._chat_log
            if hasattr(self.app, "_message_bridge")
            else None
        )
        if chat is None:
            try:
                chat = self.app.query_one("#chat-log")
            except Exception:
                return

        end = kwargs.get("end", "\n")
        for arg in args:
            # Rich renderables pass through directly
            if hasattr(arg, "__rich__") or hasattr(arg, "__rich_console__"):
                chat.write(arg)
            else:
                text = str(arg)
                # Only write non-whitespace content (avoids flooding with blank lines)
                if text.strip():
                    chat.write(text)
                elif end == "\n" and text == "\n":
                    # Explicit newlines (paragraph breaks) are OK
                    chat.write("")

    def print_exception(self, *args, **kwargs) -> None:
        """Write the current exception traceback to the chat log."""
        import traceback

        tb = traceback.format_exc()
        # Use cached chat log reference from bridge
        chat = (
            self.app._message_bridge._chat_log
            if hasattr(self.app, "_message_bridge")
            else None
        )
        if chat is None:
            try:
                chat = self.app.query_one("#chat-log")
            except Exception:
                return
        try:
            chat.write(f"[red]{tb}[/red]")
        except Exception:
            pass

    # ------------------------------------------------------------------
    # File-like API (used by renderers that need console.file)
    # ------------------------------------------------------------------

    def write(self, text: str) -> None:
        """Accept raw writes and forward to the chat log.

        ANSI escape codes are decoded via ``rich.ansi.AnsiDecoder`` so that
        the styled output appears correctly in the RichLog widget.
        """
        if not text:
            return

        # Use cached chat log reference from bridge
        chat = (
            self.app._message_bridge._chat_log
            if hasattr(self.app, "_message_bridge")
            else None
        )
        if chat is None:
            try:
                chat = self.app.query_one("#chat-log")
            except Exception:
                return

        stripped = text.strip()
        if not stripped:
            return

        # Optimization: Only use Text.from_ansi if ANSI codes are present
        # Most writes are plain text, so we avoid the overhead for the common case
        if "\x1b" in stripped or "\033" in stripped:
            # Attempt to convert ANSI codes to Rich Text for proper display
            try:
                rich_text = Text.from_ansi(stripped)
                chat.write(rich_text)
                return
            except Exception:
                # Fall back to plain text with ANSI stripped
                stripped = _strip_ansi(stripped)

        # Plain text path - no ANSI processing needed
        chat.write(stripped)

    def flush(self) -> None:
        """No-op flush (satisfies file-like interface)."""
        pass
