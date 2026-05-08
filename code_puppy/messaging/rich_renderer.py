"""Rich console renderer for structured messages.

This module implements the presentation layer for Code Puppy's messaging system.
It consumes structured messages from the MessageBus and renders them using Rich.

The renderer is responsible for ALL presentation decisions - the messages contain
only structured data with no formatting hints.
"""

import os
import re
from collections import defaultdict
from typing import Protocol, runtime_checkable

from rich.console import Console
from rich.markdown import Markdown
from rich.markup import escape as escape_rich_markup
from rich.panel import Panel
from rich.rule import Rule

# Note: Syntax import removed - file content not displayed, only header
from rich.table import Table

from code_puppy.async_utils import format_size
from code_puppy.config import get_subagent_verbose
from code_puppy.config_package import get_first_env
from code_puppy.tools.common import format_diff_with_colors
from code_puppy.utils import format_duration
from code_puppy.utils.thread_safe_cache import thread_safe_cache, thread_safe_lru_cache

# Adaptive rendering support
try:
    from code_puppy.utils.adaptive_render import (
        PayloadKind,
        classify_payload,
        collect_record_columns,
        detect_delimited_table,
        normalize_escaped_whitespace,
        python_repr_to_json,
    )

    _ADAPTIVE_RENDER_AVAILABLE = True
except ImportError:
    _ADAPTIVE_RENDER_AVAILABLE = False
from code_puppy.tools.subagent_context import is_subagent

from .bus import MessageBus
from .commands import ConfirmationResponse, SelectionResponse, UserInputResponse
from .messages import (
    AgentReasoningMessage,
    AgentResponseMessage,
    AnyMessage,
    ConfirmationRequest,
    DiffMessage,
    DividerMessage,
    FileContentMessage,
    FileListingMessage,
    GrepResultMessage,
    MessageLevel,
    SelectionRequest,
    ShellLineMessage,
    ShellOutputMessage,
    ShellStartMessage,
    SkillActivateMessage,
    SkillListMessage,
    SpinnerControl,
    StatusPanelMessage,
    SubAgentInvocationMessage,
    SubAgentResponseMessage,
    TextMessage,
    UniversalConstructorMessage,
    UserInputRequest,
    VersionCheckMessage,
)

# Note: Text and Tree were removed - no longer used in this implementation


def _get_code_theme() -> str:
    """Read the current code theme from env var at render time.

    Returns the value of CODE_PUPPY_CODE_THEME if set, otherwise 'monokai'.
    This is a function (not a module-level constant) so the /theme command
    can switch themes at runtime without requiring a restart.
    """
    return get_first_env("CODE_PUPPY_CODE_THEME") or "monokai"


# =============================================================================
# Renderer Protocol
# =============================================================================


@runtime_checkable
class RendererProtocol(Protocol):
    """Protocol defining the interface for message renderers."""

    async def render(self, message: AnyMessage) -> None:
        """Render a single message."""
        ...

    async def start(self) -> None:
        """Start the renderer (begin consuming messages)."""
        ...

    async def stop(self) -> None:
        """Stop the renderer."""
        ...


# =============================================================================
# Default Styles
# =============================================================================

DEFAULT_STYLES: dict[MessageLevel, str] = {
    MessageLevel.ERROR: "bold red",
    MessageLevel.WARNING: "yellow",
    MessageLevel.SUCCESS: "green",
    MessageLevel.INFO: "white",
    MessageLevel.DEBUG: "dim",
}

DIFF_STYLES = {
    "add": "green",
    "remove": "red",
    "context": "dim",
}

# Mapping of message levels to prefix icons
_LEVEL_PREFIXES: dict[MessageLevel, str] = {
    MessageLevel.ERROR: "✗ ",
    MessageLevel.WARNING: "⚠ ",
    MessageLevel.SUCCESS: "✓ ",
    MessageLevel.INFO: "ℹ ",
    MessageLevel.DEBUG: "• ",
}

# Mapping of file extensions to emoji icons
_FILE_ICONS: dict[str, str] = {
    # Python
    ".py": "🐍",
    ".pyw": "🐍",
    # JavaScript/TypeScript
    ".js": "📜",
    ".jsx": "📜",
    ".ts": "📜",
    ".tsx": "📜",
    # Web
    ".html": "🌐",
    ".htm": "🌐",
    ".xml": "🌐",
    ".css": "🎨",
    ".scss": "🎨",
    ".sass": "🎨",
    # Documentation
    ".md": "📝",
    ".markdown": "📝",
    ".rst": "📝",
    ".txt": "📝",
    # Config
    ".json": "⚙️",
    ".yaml": "⚙️",
    ".yml": "⚙️",
    ".toml": "⚙️",
    ".ini": "⚙️",
    # Images
    ".jpg": "🖼️",
    ".jpeg": "🖼️",
    ".png": "🖼️",
    ".gif": "🖼️",
    ".svg": "🖼️",
    ".webp": "🖼️",
    # Audio
    ".mp3": "🎵",
    ".wav": "🎵",
    ".ogg": "🎵",
    ".flac": "🎵",
    # Video
    ".mp4": "🎬",
    ".avi": "🎬",
    ".mov": "🎬",
    ".webm": "🎬",
    # Documents
    ".pdf": "📄",
    ".doc": "📄",
    ".docx": "📄",
    ".xls": "📄",
    ".xlsx": "📄",
    ".ppt": "📄",
    ".pptx": "📄",
    # Archives
    ".zip": "📦",
    ".tar": "📦",
    ".gz": "📦",
    ".rar": "📦",
    ".7z": "📦",
    # Executables
    ".exe": "⚡",
    ".dll": "⚡",
    ".so": "⚡",
    ".dylib": "⚡",
}


@thread_safe_lru_cache(maxsize=128)
def _get_file_icon_cached(file_path: str) -> str:
    """Get an emoji icon for a file based on its extension (cached)."""
    ext = os.path.splitext(file_path)[1].lower()
    return _FILE_ICONS.get(ext, "📄")


# =============================================================================
# Rich Console Renderer
# =============================================================================


class RichConsoleRenderer:
    """Rich console implementation of the renderer protocol.

    This renderer consumes messages from a MessageBus and renders them using Rich.
    It uses a background thread for synchronous compatibility with the main loop.
    """

    def __init__(
        self,
        bus: MessageBus,
        console: Console | None = None,
        styles: dict[MessageLevel, str | None] = None,
    ) -> None:
        """Initialize the renderer.

        Args:
            bus: The MessageBus to consume messages from.
            console: Rich Console instance (creates default if None).
            styles: Custom style mappings (uses DEFAULT_STYLES if None).
        """
        import threading

        self._bus = bus
        self._console = console or Console()
        self._styles = styles or DEFAULT_STYLES.copy()
        self._running = False
        self._thread: threading.Thread | None = None
        self._spinners: dict[str, object] = {}  # spinner_id -> status context
        self._wakeup_event = threading.Event()  # For efficient thread wakeup

    @property
    def console(self) -> Console:
        """Get the Rich console."""
        return self._console

    @staticmethod
    @thread_safe_cache
    def _get_banner_color(banner_name: str) -> str:
        """Get the configured color for a banner.

        Args:
            banner_name: The banner identifier (e.g., 'thinking', 'shell_command')

        Returns:
            Rich color name for the banner background
        """
        from code_puppy.config import get_banner_color

        return get_banner_color(banner_name)

    def _format_banner(self, banner_name: str, text: str) -> str:
        """Format a banner with its configured color.

        Args:
            banner_name: The banner identifier
            text: The banner text

        Returns:
            Rich markup string for the banner
        """
        color = self._get_banner_color(banner_name)
        return f"[bold white on {color}] {text} [/bold white on {color}]"

    def _should_suppress_subagent_output(self) -> bool:
        """Check if sub-agent output should be suppressed.

        Returns:
            True if we're in a sub-agent context and verbose mode is disabled
        """
        return is_subagent() and not get_subagent_verbose()

    @staticmethod
    def _count_lines(text: str) -> int:
        """Count visible lines in shell output text."""
        normalized = text.rstrip("\n")
        return len(normalized.splitlines()) if normalized else 0

    @staticmethod
    def _format_size(size_bytes: int) -> str:
        """Format a size in bytes into a human-friendly string."""
        return format_size(size_bytes)

    @staticmethod
    def _summarize_line_numbers(line_numbers: list[int], *, max_items: int = 6) -> str:
        """Build a compact summary of matching line numbers."""
        unique_lines = sorted(set(line_numbers))
        if not unique_lines:
            return "-"
        visible = ", ".join(str(num) for num in unique_lines[:max_items])
        remaining = len(unique_lines) - max_items
        if remaining > 0:
            return f"{visible}, +{remaining} more"
        return visible

    @staticmethod
    def _truncate_preview(
        text: str, *, max_lines: int = 6, max_chars: int = 400
    ) -> str:
        """Trim multiline output to a short preview for terminal display."""
        clean = text.strip("\n")
        if not clean:
            return ""
        lines = clean.splitlines()
        preview = "\n".join(lines[:max_lines])
        truncated = False
        if len(preview) > max_chars:
            preview = preview[: max_chars - 3].rstrip() + "..."
            truncated = True
        if len(lines) > max_lines and not truncated:
            preview += "\n..."
        return preview

    # =========================================================================
    # Adaptive Rendering Helpers
    # =========================================================================

    # Collapsible long-text thresholds
    _COLLAPSE_THRESHOLD_CHARS = 2000
    _COLLAPSE_PREVIEW_LINES = 40
    _COLLAPSE_PREVIEW_CHARS = 1500

    def _adaptive_render_enabled(self) -> bool:
        """Return True if adaptive rendering should be used for this message."""
        if not _ADAPTIVE_RENDER_AVAILABLE:
            return False
        try:
            from code_puppy.config import get_adaptive_rendering_enabled

            return get_adaptive_rendering_enabled()
        except Exception:
            return True  # fail-open to the new behavior

    def _render_structured_payload(self, value) -> bool:
        """Try to render a structured payload adaptively.

        Returns True if the payload was rendered (caller should skip default path),
        False if the payload should fall through to default rendering.
        """
        if not self._adaptive_render_enabled():
            return False
        try:
            kind = classify_payload(value)
            if kind == PayloadKind.KV_DICT:
                self._render_kv_table(value)
                return True
            if kind == PayloadKind.RECORD_LIST:
                self._render_record_table(value)
                return True
            # For NESTED/MIXED_LIST/SCALAR/EMPTY/STRING — fall through to default
            return False
        except Exception:
            # Never crash the renderer on adaptive-rendering bugs
            return False

    def _render_kv_table(self, payload: dict) -> None:
        """Render a flat key/value dict as a two-column Rich Table."""
        table = Table(
            show_header=True, header_style="bold cyan", box=None, padding=(0, 1)
        )
        table.add_column("Key", style="cyan", no_wrap=True)
        table.add_column("Value", style="white")
        for key, value in payload.items():
            table.add_row(str(key), "" if value is None else str(value))
        self._console.print(table)

    def _render_record_table(self, payload: list) -> None:
        """Render a list of dicts as a Rich Table with auto-detected columns."""
        columns = collect_record_columns(payload)
        if not columns:
            return
        table = Table(
            show_header=True, header_style="bold cyan", box=None, padding=(0, 1)
        )
        for col in columns:
            table.add_column(str(col), style="white")
        for row in payload:
            table.add_row(
                *[
                    "" if row.get(col) is None else str(row.get(col, ""))
                    for col in columns
                ]
            )
        self._console.print(table)

    def _adaptive_preprocess_text(self, text: str) -> str:
        """Pre-process text payloads: normalize escaped whitespace, etc."""
        if not self._adaptive_render_enabled():
            return text
        try:
            return normalize_escaped_whitespace(text)
        except Exception:
            return text

    def _try_render_embedded_table(self, text: str) -> bool:
        """Detect a delimited table embedded in the text and render it if found.

        Returns True if a table was detected and rendered, in which case the
        caller should also render any surrounding prose. Returns False if no
        table was found.
        """
        if not self._adaptive_render_enabled():
            return False
        try:
            table_info = detect_delimited_table(text)
            if table_info is None:
                return False
            table = Table(
                show_header=True,
                header_style="bold magenta",
                box=None,
                padding=(0, 1),
            )
            for col in table_info.header:
                table.add_column(col or "", style="white")
            for row in table_info.rows:
                # Pad short rows, truncate long rows
                padded = row + [""] * (len(table_info.header) - len(row))
                table.add_row(*padded[: len(table_info.header)])
            self._console.print(table)
            return True
        except Exception:
            return False

    def _try_render_python_repr(self, text: str) -> bool:
        """If text is a Python-repr dict/list, render it as pretty JSON.

        Returns True if handled.
        """
        if not self._adaptive_render_enabled():
            return False
        try:
            stripped = text.strip()
            if not stripped or stripped[0] not in "{[(":
                return False
            json_str = python_repr_to_json(stripped)
            if json_str is None:
                return False
            from rich.json import JSON

            self._console.print(JSON(json_str))
            return True
        except Exception:
            return False

    def _maybe_collapse_long_text(
        self, text: str, *, session_id: str | None = None, msg_id: str | None = None
    ) -> tuple[str, bool]:
        """Return (display_text, was_collapsed).

        If was_collapsed, display_text is a preview with a "more lines" suffix.
        """
        if not self._adaptive_render_enabled():
            return text, False
        if not isinstance(text, str) or len(text) <= self._COLLAPSE_THRESHOLD_CHARS:
            return text, False

        lines = text.splitlines()
        preview_lines = lines[: self._COLLAPSE_PREVIEW_LINES]
        preview = "\n".join(preview_lines)
        if len(preview) > self._COLLAPSE_PREVIEW_CHARS:
            preview = preview[: self._COLLAPSE_PREVIEW_CHARS]

        # Optionally write full text to session log
        log_path = self._write_collapse_log(text, session_id=session_id, msg_id=msg_id)
        remaining_lines = max(0, len(lines) - len(preview_lines))
        remaining_chars = max(0, len(text) - len(preview))
        if log_path:
            suffix = (
                f"\n[dim]... ({remaining_lines} more lines,"
                f" {remaining_chars} more chars"
                f" — full output at {log_path})[/dim]"
            )
        else:
            suffix = (
                f"\n[dim]... ({remaining_lines} more lines,"
                f" {remaining_chars} more chars"
                f" — truncated)[/dim]"
            )
        return preview + suffix, True

    def _write_collapse_log(
        self, full_text: str, *, session_id: str | None, msg_id: str | None
    ) -> str | None:
        """Atomically write full text to a per-session log file.

        Returns path or None on failure.
        """
        try:
            from datetime import datetime
            from pathlib import Path

            from code_puppy.config import DATA_DIR

            base = Path(DATA_DIR) / "logs" / (session_id or "default")
            base.mkdir(parents=True, exist_ok=True)
            fname = f"tool-{msg_id or datetime.now().strftime('%Y%m%d-%H%M%S-%f')}.log"
            path = base / fname
            tmp = path.with_suffix(path.suffix + ".tmp")
            tmp.write_text(full_text, encoding="utf-8")
            tmp.replace(path)
            return str(path)
        except Exception:
            return None

    # =========================================================================
    # Lifecycle (Synchronous - for compatibility with main.py)
    # =========================================================================

    def start(self) -> None:
        """Start the renderer in a background thread.

        This is synchronous to match the old SynchronousInteractiveRenderer API.
        """
        import threading

        if self._running:
            return

        self._running = True
        self._bus.mark_renderer_active()

        # Start background thread for message consumption
        self._thread = threading.Thread(target=self._consume_loop_sync, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop the renderer.

        This is synchronous to match the old SynchronousInteractiveRenderer API.
        """
        self._running = False
        self._bus.mark_renderer_inactive()
        self._wakeup()  # Wake up the loop so it can exit

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._thread = None

    def _wakeup(self) -> None:
        """Wake up the renderer thread to check for new messages."""
        self._wakeup_event.set()

    def _consume_loop_sync(self) -> None:
        """Synchronous message consumption loop running in background thread."""
        # First, process any buffered messages
        for msg in self._bus.get_buffered_messages():
            self._render_sync(msg)

        # Register wakeup callback so bus can signal us when new messages arrive
        self._bus.register_wakeup_callback(self._wakeup)

        # Then consume new messages with event-driven wakeup
        while self._running:
            message = self._bus.get_message_nowait()
            if message:
                self._render_sync(message)
            else:
                # Wait until wakeup event or timeout (near-zero CPU when idle)
                self._wakeup_event.wait(timeout=0.1)
                self._wakeup_event.clear()

    def _render_sync(self, message: AnyMessage) -> None:
        """Render a message synchronously with error handling."""
        try:
            self._do_render(message)
        except Exception as e:
            # Don't let rendering errors crash the loop
            # Escape the error message to prevent nested markup errors
            safe_error = escape_rich_markup(str(e))
            self._console.print(f"[dim red]Render error: {safe_error}[/dim red]")

    # =========================================================================
    # Async Lifecycle (for future async-first usage)
    # =========================================================================

    async def start_async(self) -> None:
        """Start the renderer asynchronously."""
        if self._running:
            return

        self._running = True
        self._bus.mark_renderer_active()

        # Process any buffered messages first
        for msg in self._bus.get_buffered_messages():
            self._render_sync(msg)

    async def stop_async(self) -> None:
        """Stop the renderer asynchronously."""
        self._running = False
        self._bus.mark_renderer_inactive()

    # =========================================================================
    # Main Dispatch
    # =========================================================================

    def _do_render(self, message: AnyMessage) -> None:
        """Synchronously render a message by dispatching to the appropriate handler.

        Note: User input requests are skipped in sync mode as they require async.
        """
        # Dispatch based on message type
        if isinstance(message, TextMessage):
            self._render_text(message)
        elif isinstance(message, FileListingMessage):
            self._render_file_listing(message)
        elif isinstance(message, FileContentMessage):
            self._render_file_content(message)
        elif isinstance(message, GrepResultMessage):
            self._render_grep_result(message)
        elif isinstance(message, DiffMessage):
            self._render_diff(message)
        elif isinstance(message, ShellStartMessage):
            self._render_shell_start(message)
        elif isinstance(message, ShellLineMessage):
            self._render_shell_line(message)
        elif isinstance(message, ShellOutputMessage):
            self._render_shell_output(message)
        elif isinstance(message, AgentReasoningMessage):
            self._render_agent_reasoning(message)
        elif isinstance(message, AgentResponseMessage):
            self._render_agent_response(message)
        elif isinstance(message, SubAgentInvocationMessage):
            self._render_subagent_invocation(message)
        elif isinstance(message, SubAgentResponseMessage):
            self._render_subagent_response(message)
        elif isinstance(message, UniversalConstructorMessage):
            self._render_universal_constructor(message)
        elif isinstance(message, UserInputRequest):
            # Can't handle async user input in sync context - skip
            self._console.print("[dim]User input requested (requires async)[/dim]")
        elif isinstance(message, ConfirmationRequest):
            # Can't handle async confirmation in sync context - skip
            self._console.print("[dim]Confirmation requested (requires async)[/dim]")
        elif isinstance(message, SelectionRequest):
            # Can't handle async selection in sync context - skip
            self._console.print("[dim]Selection requested (requires async)[/dim]")
        elif isinstance(message, SpinnerControl):
            self._render_spinner_control(message)
        elif isinstance(message, DividerMessage):
            self._render_divider(message)
        elif isinstance(message, StatusPanelMessage):
            self._render_status_panel(message)
        elif isinstance(message, VersionCheckMessage):
            self._render_version_check(message)
        elif isinstance(message, SkillListMessage):
            self._render_skill_list(message)
        elif isinstance(message, SkillActivateMessage):
            self._render_skill_activate(message)
        else:
            # Unknown message type - render as debug
            self._console.print(f"[dim]Unknown message: {type(message).__name__}[/dim]")

    async def render(self, message: AnyMessage) -> None:
        """Render a message asynchronously (supports user input requests)."""
        # Handle async-only message types
        if isinstance(message, UserInputRequest):
            await self._render_user_input_request(message)
        elif isinstance(message, ConfirmationRequest):
            await self._render_confirmation_request(message)
        elif isinstance(message, SelectionRequest):
            await self._render_selection_request(message)
        else:
            # Use sync render for everything else
            self._do_render(message)

    # =========================================================================
    # Text Messages
    # =========================================================================

    def _render_text(self, msg: TextMessage) -> None:
        """Render a text message with appropriate styling.

        Text is escaped to prevent Rich markup injection which could crash
        the renderer if malformed tags are present in shell output or other
        user-provided content.
        """
        style = self._styles.get(msg.level, "white")

        # Make version messages dim
        if "Current version:" in msg.text or "Latest version:" in msg.text:
            style = "dim"

        prefix = self._get_level_prefix(msg.level)

        # Adaptive rendering integration
        # Only for non-markdown text; markdown content is already structured
        if not msg.is_markdown and isinstance(msg.text, str):
            # Pre-process: normalize escaped whitespace
            text = self._adaptive_preprocess_text(msg.text)

            # Try structured detection for Python repr content
            if self._try_render_python_repr(text):
                return

            # Try embedded table detection (renders alongside prose)
            self._try_render_embedded_table(text)

            # Check for long text and collapse if needed
            text, was_collapsed = self._maybe_collapse_long_text(text)
        else:
            text = msg.text

        if msg.is_markdown:
            # Render as markdown (prefix printed separately to preserve level icon)
            try:
                if prefix:
                    self._console.print(prefix, style=style, end="")
                md = Markdown(text, code_theme=_get_code_theme())
                self._console.print(md)
            except Exception as exc:  # noqa: BLE001
                import logging

                logging.getLogger(__name__).debug(
                    "Markdown render failed, falling back to plain text: %s", exc
                )
                safe_text = escape_rich_markup(text)
                self._console.print(f"{prefix}{safe_text}", style=style)
        else:
            # Plain-text path with Rich markup escaping
            safe_text = escape_rich_markup(text)
            self._console.print(f"{prefix}{safe_text}", style=style)

    def _get_level_prefix(self, level: MessageLevel) -> str:
        """Get a prefix icon for the message level."""
        return _LEVEL_PREFIXES.get(level, "")

    # =========================================================================
    # File Operations
    # =========================================================================

    def _render_file_listing(self, msg: FileListingMessage) -> None:
        """Render a compact directory listing with directory summaries.

        Instead of listing every file, we group by directory and show:
        - Directory name
        - Number of files
        - Total size
        - Number of subdirectories
        """
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Header on single line
        rec_flag = f"(recursive={msg.recursive})"
        banner = self._format_banner("directory_listing", "DIRECTORY LISTING")
        self._console.print(
            f"\n{banner} "
            f"📂 [bold cyan]{msg.directory}[/bold cyan] [dim]{rec_flag}[/dim]\n"
        )

        # Build a tree structure: {parent_path: {files: [], dirs: set(), size: int}}
        # Each key is a directory path, value contains direct children stats
        dir_stats: dict = defaultdict(
            lambda: {"files": [], "subdirs": set(), "total_size": 0}
        )

        # Root directory is represented as ""
        root_key = ""

        for entry in msg.files:
            path = entry.path
            parent = os.path.dirname(path) if os.path.dirname(path) else root_key

            if entry.type == "dir":
                # Register this dir as a subdir of its parent
                dir_stats[parent]["subdirs"].add(path)
                # Ensure the dir itself exists in stats (even if empty)
                _ = dir_stats[path]
            else:
                # It's a file - add to parent's stats
                dir_stats[parent]["files"].append(entry)
                dir_stats[parent]["total_size"] += entry.size

        # Bottom-up memoization: compute all directory sizes in a single pass
        size_cache: dict[str, int] = {}
        file_count_cache: dict[str, int] = {}

        def compute_recursive_stats(dir_path: str) -> tuple[int, int]:
            """Compute size and file count for a directory and all subdirectories.

            Uses post-order traversal (bottom-up) to ensure children are computed
            before parents. Results are memoized in size_cache and file_count_cache.
            """
            if dir_path in size_cache:
                return size_cache[dir_path], file_count_cache[dir_path]

            stats = dir_stats.get(
                dir_path, {"files": [], "subdirs": set(), "total_size": 0}
            )
            total_size = stats["total_size"]
            total_files = len(stats["files"])

            # Recursively compute for all subdirectories first (post-order)
            for sub in stats["subdirs"]:
                sub_size, sub_files = compute_recursive_stats(sub)
                total_size += sub_size
                total_files += sub_files

            size_cache[dir_path] = total_size
            file_count_cache[dir_path] = total_files
            return total_size, total_files

        # Pre-compute all directory sizes in a single bottom-up pass
        all_dirs = list(dir_stats.keys())
        for d in all_dirs:
            if d not in size_cache:
                compute_recursive_stats(d)

        def render_dir_tree(
            dir_path: str,
            depth: int = 0,
        ) -> None:
            """Render directory with compact summary using pre-computed stats."""
            stats = dir_stats.get(
                dir_path, {"files": [], "subdirs": set(), "total_size": 0}
            )
            files = stats["files"]
            subdirs = sorted(stats["subdirs"])

            indent = "    " * depth

            # For root level, just show contents
            if dir_path == root_key:
                # Show files at root level (depth 0)
                for f in sorted(files, key=lambda x: x.path):
                    icon = self._get_file_icon(f.path)
                    name = os.path.basename(f.path)
                    size_str = (
                        f" [dim]({format_size(f.size)})[/dim]" if f.size > 0 else ""
                    )
                    self._console.print(
                        f"{indent}{icon} [green]{name}[/green]{size_str}"
                    )

                # Show subdirs at root level
                for subdir in subdirs:
                    render_dir_tree(subdir, depth)
            else:
                # Show directory with summary (use pre-computed cache values)
                dir_name = os.path.basename(dir_path)
                rec_size = size_cache.get(dir_path, 0)
                rec_file_count = file_count_cache.get(dir_path, 0)
                subdir_count = len(subdirs)

                # Build summary parts
                parts = []
                if rec_file_count > 0:
                    parts.append(
                        f"{rec_file_count} file{'s' if rec_file_count != 1 else ''}"
                    )
                if subdir_count > 0:
                    parts.append(
                        f"{subdir_count} subdir{'s' if subdir_count != 1 else ''}"
                    )
                if rec_size > 0:
                    parts.append(format_size(rec_size))

                summary = f" [dim]({', '.join(parts)})[/dim]" if parts else ""
                self._console.print(
                    f"{indent}📁 [bold blue]{dir_name}/[/bold blue]{summary}"
                )

                # Recursively show subdirectories
                for subdir in subdirs:
                    render_dir_tree(subdir, depth + 1)

        # Render the tree starting from root
        render_dir_tree(root_key, 0)

        # Summary
        self._console.print("\n[bold cyan]Summary:[/bold cyan]")
        self._console.print(
            f"📁 [blue]{msg.dir_count} directories[/blue], "
            f"📄 [green]{msg.file_count} files[/green] "
            f"[dim]({format_size(msg.total_size)} total)[/dim]"
        )

    def _render_file_content(self, msg: FileContentMessage) -> None:
        """Render a file read - just show the header, not the content.

        The file content is for the LLM only, not for display in the UI.
        """
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Build line info
        line_info = ""
        if msg.start_line is not None and msg.num_lines is not None:
            end_line = msg.start_line + msg.num_lines - 1
            line_info = f" [dim](lines {msg.start_line}-{end_line})[/dim]"

        # Just print the header - content is for LLM only
        banner = self._format_banner("read_file", "READ FILE")
        self._console.print(
            f"\n{banner} 📂 [bold cyan]{msg.path}[/bold cyan]{line_info}"
        )

    def _render_grep_result(self, msg: GrepResultMessage) -> None:
        """Render grep results grouped by file matching old format."""
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Header
        banner = self._format_banner("grep", "GREP")
        self._console.print(
            f"\n{banner} 📂 [dim]{msg.directory} for '{msg.search_term}'[/dim]"
        )

        if not msg.matches:
            self._console.print(
                f"[dim]No matches found for '{msg.search_term}' "
                f"in {msg.directory}[/dim]"
            )
            return

        # Group by file
        by_file: dict[str, list] = {}
        for match in msg.matches:
            by_file.setdefault(match.file_path, []).append(match)

        # Show verbose or concise based on message flag
        if msg.verbose:
            # Extract the actual search term (not ripgrep flags) once
            parts = msg.search_term.split()
            search_term = msg.search_term  # fallback
            for part in parts:
                if not part.startswith("-"):
                    search_term = part
                    break

            # Pre-compile regex for highlighting if we have a valid search term
            highlight_regex = None
            if search_term and not search_term.startswith("-"):
                highlight_regex = re.compile(
                    f"({re.escape(search_term)})",
                    flags=re.IGNORECASE,
                )

            # Verbose mode: Show full output with line numbers and content
            for file_path in sorted(by_file.keys()):
                file_matches = by_file[file_path]
                match_word = "match" if len(file_matches) == 1 else "matches"

                # Build line number summary
                line_numbers = [m.line_number for m in file_matches]
                lines_summary = self._summarize_line_numbers(line_numbers)

                self._console.print(
                    f"\n[dim]📄 {file_path} ({len(file_matches)} {match_word}) "
                    f"lines: {lines_summary}[/dim]"
                )

                # Show each match with line number and content
                for match in file_matches:
                    line = match.line_content

                    # Case-insensitive highlighting using pre-compiled regex
                    if highlight_regex:
                        highlighted_line = highlight_regex.sub(
                            r"[bold yellow]\1[/bold yellow]",
                            line,
                        )
                    else:
                        highlighted_line = line

                    ln = match.line_number
                    self._console.print(f"  [dim]{ln:4d}[/dim] │ {highlighted_line}")
        else:
            # Concise mode (default): Show aligned table format
            self._console.print("")
            table = Table.grid(padding=(0, 2))
            table.add_column(style="dim", no_wrap=True)  # icon + file
            table.add_column(style="bold cyan", justify="right", no_wrap=True)  # count
            table.add_column(style="dim", no_wrap=True)  # unit

            for file_path in sorted(by_file.keys()):
                file_matches = by_file[file_path]
                match_word = "match" if len(file_matches) == 1 else "matches"
                table.add_row(f"📄 {file_path}", str(len(file_matches)), match_word)

            self._console.print(table)

        # Summary with files_searched included
        match_word = "match" if msg.total_matches == 1 else "matches"
        file_word = "file" if len(by_file) == 1 else "files"
        num_files = len(by_file)
        self._console.print(
            f"[dim]Found {msg.total_matches} {match_word}"
            f" across {num_files} {file_word}"
            f" (searched {msg.files_searched} files)[/dim]"
        )

        # Trailing newline for spinner separation
        self._console.print()

    # =========================================================================
    # Diff
    # =========================================================================

    def _render_diff(self, msg: DiffMessage) -> None:
        """Render a diff with beautiful syntax highlighting."""
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Operation-specific styling
        op_icons = {"create": "✨", "modify": "✏️", "delete": "🗑️"}
        op_colors = {"create": "green", "modify": "yellow", "delete": "red"}
        icon = op_icons.get(msg.operation, "📄")
        op_color = op_colors.get(msg.operation, "white")

        # Choose banner based on operation type
        if msg.operation == "create":
            banner = self._format_banner("create_file", "CREATE FILE")
        elif msg.operation == "delete":
            banner = self._format_banner("delete_file", "DELETE FILE")
        else:
            banner = self._format_banner("replace_in_file", "EDIT FILE")
        self._console.print(
            f"\n{banner} "
            f"{icon} [{op_color}]{msg.operation.upper()}[/{op_color}] "
            f"[bold cyan]{msg.path}[/bold cyan]"
        )

        if not msg.diff_lines:
            return

        # Reconstruct unified diff text from diff_lines for format_diff_with_colors
        diff_text_lines = []
        for line in msg.diff_lines:
            if line.type == "add":
                diff_text_lines.append(f"+{line.content}")
            elif line.type == "remove":
                diff_text_lines.append(f"-{line.content}")
            else:  # context
                # Don't add space prefix to diff headers - they need to be preserved
                # exactly for syntax highlighting to detect the file extension
                if line.content.startswith(("---", "+++", "@@", "diff ", "index ")):
                    diff_text_lines.append(line.content)
                else:
                    diff_text_lines.append(f" {line.content}")

        diff_text = "\n".join(diff_text_lines)

        # Use the beautiful syntax-highlighted diff formatter
        formatted_diff = format_diff_with_colors(diff_text)
        self._console.print(formatted_diff)

    # =========================================================================
    # Shell Output
    # =========================================================================

    def _render_shell_start(self, msg: ShellStartMessage) -> None:
        """Render shell command start notification."""
        if self._should_suppress_subagent_output():
            return

        safe_command = escape_rich_markup(msg.command)
        banner = self._format_banner("shell_command", "SHELL COMMAND")
        self._console.print(f"\n{banner} 🚀")

        details = Table.grid(padding=(0, 2))
        details.add_column(style="bold cyan", no_wrap=True)
        details.add_column(style="white")
        details.add_row("Command", f"$ {safe_command}")

        if msg.cwd:
            safe_cwd = escape_rich_markup(msg.cwd)
            details.add_row("Directory", safe_cwd)

        mode_text = "BACKGROUND 🌙" if msg.background else "FOREGROUND"
        timeout_text = (
            "Runs detached (no timeout)"
            if msg.background
            else format_duration(float(msg.timeout))
        )
        details.add_row("Mode", mode_text)
        details.add_row("Timeout", timeout_text)

        self._console.print(Panel.fit(details, border_style="magenta", padding=(0, 1)))

    def _render_shell_line(self, msg: ShellLineMessage) -> None:
        """Render shell output line preserving ANSI codes and carriage returns."""
        import sys

        from rich.text import Text

        if "\r" in msg.line:
            sys.stdout.write(f"\033[2m{msg.line}\033[0m")
            sys.stdout.flush()
        else:
            if "\033[" in msg.line:
                text = Text.from_ansi(msg.line)
            else:
                text = Text(msg.line)
            style = "yellow" if msg.stream == "stderr" else "dim"
            self._console.print(text, style=style)

    def _render_shell_output(self, msg: ShellOutputMessage) -> None:
        """Render a compact shell command completion summary."""
        stdout_lines = self._count_lines(msg.stdout)
        stderr_lines = self._count_lines(msg.stderr)
        success = msg.exit_code == 0
        border_style = "green" if success else "red"
        title = (
            "[bold green]✓ COMMAND FINISHED[/bold green]"
            if success
            else "[bold red]✗ COMMAND FAILED[/bold red]"
        )

        summary = Table.grid(padding=(0, 2))
        summary.add_column(style="bold cyan", no_wrap=True)
        summary.add_column(style="white")
        summary.add_row("Exit", str(msg.exit_code))
        summary.add_row("Duration", format_duration(msg.duration_seconds))
        summary.add_row(
            "Stdout",
            f"{stdout_lines} line(s)" if stdout_lines else "empty",
        )
        summary.add_row(
            "Stderr",
            f"{stderr_lines} line(s)" if stderr_lines else "empty",
        )

        self._console.print(Panel.fit(summary, title=title, border_style=border_style))

        # Show stderr preview on failure or if there's stderr content
        stderr_preview = self._truncate_preview(msg.stderr)
        if stderr_preview:
            self._console.print(
                Panel.fit(
                    escape_rich_markup(stderr_preview),
                    title="[bold yellow]stderr preview[/bold yellow]",
                    border_style="yellow",
                    padding=(0, 1),
                )
            )
        elif not success:
            # If no stderr but command failed, show stdout preview
            stdout_preview = self._truncate_preview(msg.stdout)
            if stdout_preview:
                self._console.print(
                    Panel.fit(
                        escape_rich_markup(stdout_preview),
                        title="[bold cyan]stdout preview[/bold cyan]",
                        border_style="cyan",
                        padding=(0, 1),
                    )
                )

    # =========================================================================
    # Agent Messages
    # =========================================================================

    def _render_agent_reasoning(self, msg: AgentReasoningMessage) -> None:
        """Render agent reasoning matching old format."""
        # Header matching old format
        banner = self._format_banner("agent_reasoning", "AGENT REASONING")
        self._console.print(f"\n{banner}")

        # Current reasoning
        self._console.print("[bold cyan]Current reasoning:[/bold cyan]")
        # Render reasoning as markdown
        md = Markdown(msg.reasoning, code_theme=_get_code_theme())
        self._console.print(md)

        # Next steps (if any)
        if msg.next_steps and msg.next_steps.strip():
            self._console.print("\n[bold cyan]Planned next steps:[/bold cyan]")
            md_steps = Markdown(msg.next_steps, code_theme=_get_code_theme())
            self._console.print(md_steps)

        # Trailing newline for spinner separation
        self._console.print()

    def _render_agent_response(self, msg: AgentResponseMessage) -> None:
        """Render agent response with header and markdown formatting."""
        # If content was already streamed, erase it before re-rendering as markdown
        if msg.was_streamed and msg.streamed_line_count > 0:
            # Erase the previously-streamed plain text output
            # Move cursor up N lines and clear each line
            import sys

            for _ in range(msg.streamed_line_count):
                sys.stdout.write("\033[A\033[2K")  # Move up + clear line
            sys.stdout.write("\033[G")  # Move cursor to column 0
            sys.stdout.flush()

        # Header
        banner = self._format_banner("agent_response", "AGENT RESPONSE")
        self._console.print(f"\n{banner}\n")

        # Content (markdown or plain)
        if msg.is_markdown:
            md = Markdown(msg.content, code_theme=_get_code_theme())
            self._console.print(md)
        else:
            self._console.print(msg.content)

    def _render_subagent_invocation(self, msg: SubAgentInvocationMessage) -> None:
        """Render sub-agent invocation header with nice formatting."""
        # Skip for sub-agents unless verbose mode (avoid nested invocation banners)
        if self._should_suppress_subagent_output():
            return

        # Header with agent name and session
        session_type = (
            "New session"
            if msg.is_new_session
            else f"Continuing ({msg.message_count} messages)"
        )
        banner = self._format_banner("invoke_agent", "🤖 INVOKE AGENT")
        self._console.print(
            f"\n{banner} "
            f"[bold cyan]{msg.agent_name}[/bold cyan] "
            f"[dim]({session_type})[/dim]"
        )

        # Session ID
        self._console.print(f"[dim]Session:[/dim] [bold]{msg.session_id}[/bold]")

        # Prompt (truncated if too long, rendered as markdown)
        prompt_display = (
            msg.prompt[:200] + "..." if len(msg.prompt) > 200 else msg.prompt
        )
        self._console.print("[dim]Prompt:[/dim]")
        md_prompt = Markdown(prompt_display, code_theme=_get_code_theme())
        self._console.print(md_prompt)

    def _render_subagent_response(self, msg: SubAgentResponseMessage) -> None:
        """Render sub-agent response with markdown formatting."""
        # If content was already streamed, erase it before re-rendering as markdown
        if msg.was_streamed and msg.streamed_line_count > 0:
            # Erase the previously-streamed plain text output
            # Move cursor up N lines and clear each line
            import sys

            for _ in range(msg.streamed_line_count):
                sys.stdout.write("\033[A\033[2K")  # Move up + clear line
            sys.stdout.write("\033[G")  # Move cursor to column 0
            sys.stdout.flush()

        # Response header
        banner = self._format_banner("subagent_response", "✓ AGENT RESPONSE")
        self._console.print(f"\n{banner} [bold cyan]{msg.agent_name}[/bold cyan]")

        # Render response as markdown
        md = Markdown(msg.response, code_theme=_get_code_theme())
        self._console.print(md)

        # Footer with session info
        self._console.print(
            f"\n[dim]Session [bold]{msg.session_id}[/bold] saved "
            f"({msg.message_count} messages)[/dim]"
        )

    def _render_universal_constructor(self, msg: UniversalConstructorMessage) -> None:
        """Render universal_constructor tool output with banner."""
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Format banner
        banner = self._format_banner("universal_constructor", "UNIVERSAL CONSTRUCTOR")

        # Build the header line with action and optional tool name
        # Escape user-controlled strings to prevent Rich markup injection
        header_parts = [f"\n{banner} 🔧 [bold cyan]{msg.action.upper()}[/bold cyan]"]
        if msg.tool_name:
            safe_tool_name = escape_rich_markup(msg.tool_name)
            header_parts.append(f" [dim]tool=[/dim][bold]{safe_tool_name}[/bold]")
        self._console.print("".join(header_parts))

        # Status indicator
        safe_summary = escape_rich_markup(msg.summary) if msg.summary else ""
        if msg.success:
            self._console.print(f"[green]✓[/green] {safe_summary}")
        else:
            self._console.print(f"[red]✗[/red] {safe_summary}")

        # Show details if present
        if msg.details:
            # Adaptive rendering for details
            # Try structured detection before falling back to plain text
            details = self._adaptive_preprocess_text(msg.details)
            if self._try_render_python_repr(details):
                pass  # Handled by adaptive renderer
            elif self._try_render_embedded_table(details):
                # Table rendered; still show surrounding text if any
                safe_details = escape_rich_markup(details)
                self._console.print(f"[dim]{safe_details}[/dim]")
            else:
                # Default: plain escaped text
                safe_details = escape_rich_markup(details)
                self._console.print(f"[dim]{safe_details}[/dim]")

        # Trailing newline for spinner separation
        self._console.print()

    # =========================================================================
    # User Interaction
    # =========================================================================

    async def _render_user_input_request(self, msg: UserInputRequest) -> None:
        """Render input prompt and send response back to bus."""
        prompt = msg.prompt_text
        if msg.default_value:
            prompt += f" [{msg.default_value}]"
        prompt += ": "

        # Get input (password hides input)
        if msg.input_type == "password":
            value = self._console.input(prompt, password=True)
        else:
            value = self._console.input(f"[cyan]{prompt}[/cyan]")

        # Use default if empty
        if not value and msg.default_value:
            value = msg.default_value

        # Send response back
        response = UserInputResponse(prompt_id=msg.prompt_id, value=value)
        self._bus.provide_response(response)

    async def _render_confirmation_request(self, msg: ConfirmationRequest) -> None:
        """Render confirmation dialog and send response back."""
        # Show title and description - escape to prevent markup injection
        safe_title = escape_rich_markup(msg.title)
        safe_description = escape_rich_markup(msg.description)
        self._console.print(f"\n[bold yellow]{safe_title}[/bold yellow]")
        self._console.print(safe_description)

        # Show options
        options_str = "/".join(msg.options)
        prompt = f"[{options_str}]"

        while True:
            choice = self._console.input(f"[cyan]{prompt}[/cyan] ").strip().lower()

            # Check for match
            for i, opt in enumerate(msg.options):
                if choice == opt.lower() or choice == opt[0].lower():
                    confirmed = i == 0  # First option is "confirm"

                    # Get feedback if allowed
                    feedback = None
                    if msg.allow_feedback:
                        feedback = self._console.input(
                            "[dim]Feedback (optional): [/dim]"
                        )
                        feedback = feedback if feedback else None

                    response = ConfirmationResponse(
                        prompt_id=msg.prompt_id, confirmed=confirmed, feedback=feedback
                    )
                    self._bus.provide_response(response)
                    return

            self._console.print(f"[red]Please enter one of: {options_str}[/red]")

    async def _render_selection_request(self, msg: SelectionRequest) -> None:
        """Render selection menu and send response back."""
        safe_prompt = escape_rich_markup(msg.prompt_text)
        self._console.print(f"\n[bold]{safe_prompt}[/bold]")

        # Show numbered options - escape to prevent markup injection
        for i, opt in enumerate(msg.options):
            safe_opt = escape_rich_markup(opt)
            self._console.print(f"  [cyan]{i + 1}[/cyan]. {safe_opt}")

        if msg.allow_cancel:
            self._console.print("  [dim]0. Cancel[/dim]")

        while True:
            choice = self._console.input("[cyan]Enter number: [/cyan]").strip()

            try:
                idx = int(choice)
                if msg.allow_cancel and idx == 0:
                    response = SelectionResponse(
                        prompt_id=msg.prompt_id, selected_index=-1, selected_value=""
                    )
                    self._bus.provide_response(response)
                    return

                if 1 <= idx <= len(msg.options):
                    response = SelectionResponse(
                        prompt_id=msg.prompt_id,
                        selected_index=idx - 1,
                        selected_value=msg.options[idx - 1],
                    )
                    self._bus.provide_response(response)
                    return
            except ValueError:
                pass

            self._console.print(f"[red]Please enter 1-{len(msg.options)}[/red]")

    # =========================================================================
    # Control Messages
    # =========================================================================

    def _render_spinner_control(self, msg: SpinnerControl) -> None:
        """Handle spinner control messages."""
        # Note: Rich's spinner/status is typically used as a context manager.
        # For full spinner support, we'd need a more complex implementation.
        # For now, we just print the status text.
        if msg.action == "start" and msg.text:
            self._console.print(f"[dim]⠋ {msg.text}[/dim]")
        elif msg.action == "update" and msg.text:
            self._console.print(f"[dim]⠋ {msg.text}[/dim]")
        elif msg.action == "stop":
            pass  # Spinner stopped

    def _render_divider(self, msg: DividerMessage) -> None:
        """Render a horizontal divider."""
        chars = {"light": "─", "heavy": "━", "double": "═"}
        char = chars.get(msg.style, "─")
        rule = Rule(style="dim", characters=char)
        self._console.print(rule)

    # =========================================================================
    # Status Messages
    # =========================================================================

    def _render_status_panel(self, msg: StatusPanelMessage) -> None:
        """Render a status panel with key-value fields."""
        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column("Key", style="bold cyan")
        table.add_column("Value")

        for key, value in msg.fields.items():
            table.add_row(key, value)

        panel = Panel(table, title=f"[bold]{msg.title}[/bold]", border_style="blue")
        self._console.print(panel)

    def _render_version_check(self, msg: VersionCheckMessage) -> None:
        """Render version check information."""
        if msg.update_available:
            cur = msg.current_version
            latest = msg.latest_version
            self._console.print(f"[dim]⬆ Update available: {cur} → {latest}[/dim]")
        else:
            self._console.print(
                f"[dim]✓ You're on the latest version ({msg.current_version})[/dim]"
            )

    # =========================================================================
    # Helpers
    # =========================================================================

    def _get_file_icon(self, file_path: str) -> str:
        """Get an emoji icon for a file based on its extension."""
        return _get_file_icon_cached(file_path)

    # =========================================================================
    # Skills
    # =========================================================================

    def _render_skill_list(self, msg: SkillListMessage) -> None:
        """Render a list of available skills."""
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Banner
        banner = self._format_banner("agent_response", "LIST SKILLS")
        query_info = f" matching [cyan]'{msg.query}'[/cyan]" if msg.query else ""
        self._console.print(
            f"\n{banner} 🛠️ Found [bold]{msg.total_count}[/bold] skill(s){query_info}\n"
        )

        if not msg.skills:
            self._console.print("[dim]  No skills found.[/dim]")
            self._console.print(
                "[dim]  Install skills in ~/.code_puppy/skills/[/dim]\n"
            )
            return

        # Create a table for skills
        table = Table(show_header=True, header_style="bold", box=None, padding=(0, 2))
        table.add_column("Status", style="dim", width=8)
        table.add_column("Name", style="cyan")
        table.add_column("Description", style="dim")
        table.add_column("Tags", style="yellow dim")

        for skill in msg.skills:
            status = "[green]✓[/green]" if skill.enabled else "[red]✗[/red]"
            tags = ", ".join(skill.tags[:3]) if skill.tags else "-"
            # Truncate description if too long
            desc = skill.description
            if len(desc) > 50:
                desc = desc[:47] + "..."
            table.add_row(status, skill.name, desc, tags)

        self._console.print(table)
        self._console.print()

    def _render_skill_activate(self, msg: SkillActivateMessage) -> None:
        """Render skill activation result."""
        # Skip for sub-agents unless verbose mode
        if self._should_suppress_subagent_output():
            return

        # Banner
        banner = self._format_banner("agent_response", "ACTIVATE SKILL")
        status = "[green]✓[/green]" if msg.success else "[red]✗[/red]"
        self._console.print(
            f"\n{banner} {status} [bold cyan]{msg.skill_name}[/bold cyan]\n"
        )

        if msg.success:
            # Show path
            self._console.print(f"  [dim]Path:[/dim] {msg.skill_path}")

            # Show resource count
            if msg.resource_count > 0:
                self._console.print(
                    f"  [dim]Resources:[/dim] {msg.resource_count} bundled file(s)"
                )

            # Show preview
            if msg.content_preview:
                preview = msg.content_preview.replace("\n", " ")[:100]
                if len(msg.content_preview) > 100:
                    preview += "..."
                self._console.print(f"  [dim]Preview:[/dim] {preview}")
        else:
            self._console.print("  [red]Activation failed[/red]")

        self._console.print()


# =============================================================================
# Export all public symbols
# =============================================================================

__all__ = [
    "RendererProtocol",
    "RichConsoleRenderer",
    "DEFAULT_STYLES",
    "DIFF_STYLES",
]
