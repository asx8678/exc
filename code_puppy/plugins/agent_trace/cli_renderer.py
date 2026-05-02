"""Agent Trace V2 — CLI Live Renderer.

Renders trace state directly in the terminal during agent execution.
No slash commands needed - displays automatically as agents run.

Key features:
- Tree view showing agent → model → tool hierarchy
- Token counts with accounting state indicators
- Live updates during streaming
- Reconciliation feedback when estimates are corrected
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass
from typing import TextIO

from code_puppy.plugins.agent_trace.reducer import SpanState, TokenUsage, TraceState
from code_puppy.plugins.agent_trace.schema import AccountingState, NodeKind

# ═══════════════════════════════════════════════════════════════════════════════
# ANSI Color Codes
# ═══════════════════════════════════════════════════════════════════════════════


class Colors:
    """ANSI color codes for terminal output."""

    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"

    # Status colors
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    BLUE = "\033[34m"
    CYAN = "\033[36m"
    MAGENTA = "\033[35m"
    WHITE = "\033[37m"

    # Background
    BG_BLACK = "\033[40m"

    @classmethod
    def disable(cls) -> None:
        """Disable colors (for non-TTY output)."""
        for attr in dir(cls):
            if not attr.startswith("_") and attr.isupper():
                setattr(cls, attr, "")


# Check if we're in a TTY
if not sys.stdout.isatty():
    Colors.disable()


# ═══════════════════════════════════════════════════════════════════════════════
# Box Drawing Characters
# ═══════════════════════════════════════════════════════════════════════════════


class Box:
    """Unicode box drawing characters."""

    # Corners
    TL = "┌"  # Top-left
    TR = "┐"  # Top-right
    BL = "└"  # Bottom-left
    BR = "┘"  # Bottom-right

    # Lines
    H = "─"  # Horizontal
    V = "│"  # Vertical

    # T-junctions
    T_RIGHT = "├"  # T pointing right
    T_LEFT = "┤"  # T pointing left

    # Tree branches
    BRANCH = "├─"
    LAST = "└─"
    PIPE = "│ "
    SPACE = "  "


# ═══════════════════════════════════════════════════════════════════════════════
# Status Icons
# ═══════════════════════════════════════════════════════════════════════════════


class Icons:
    """Status and type icons."""

    # Status
    RUNNING = "⏳"
    STREAMING = "◐"  # Animated feel
    DONE = "✓"
    FAILED = "✗"

    # Node types
    AGENT = "🤖"
    MODEL = "🧠"
    TOOL = "🔧"

    # Accounting state
    ESTIMATED = "~"  # Tilde for estimated
    EXACT = "✓"  # Check for exact
    RECONCILED = "⟳"  # Cycle for reconciled
    UNKNOWN = "?"


# ═══════════════════════════════════════════════════════════════════════════════
# Formatting Helpers
# ═══════════════════════════════════════════════════════════════════════════════


def _format_tokens(usage: TokenUsage) -> str:
    """Format token count with accounting state indicator."""
    if usage.output_tokens == 0 and usage.input_tokens == 0:
        return ""

    # Choose indicator based on accounting state
    if usage.accounting == AccountingState.ESTIMATED_LIVE:
        indicator = f"{Colors.YELLOW}{Icons.ESTIMATED}{Colors.RESET}"
        prefix = "~"
    elif usage.accounting == AccountingState.PROVIDER_REPORTED_EXACT:
        indicator = f"{Colors.GREEN}{Icons.EXACT}{Colors.RESET}"
        prefix = ""
    elif usage.accounting == AccountingState.RECONCILED:
        indicator = f"{Colors.CYAN}{Icons.RECONCILED}{Colors.RESET}"
        prefix = ""
    else:
        indicator = f"{Colors.DIM}{Icons.UNKNOWN}{Colors.RESET}"
        prefix = "?"

    parts = []
    if usage.input_tokens > 0:
        parts.append(f"{prefix}{usage.input_tokens} in")
    if usage.output_tokens > 0:
        parts.append(f"{prefix}{usage.output_tokens} out")
    if usage.reasoning_tokens > 0:
        parts.append(f"{usage.reasoning_tokens} think")

    tokens_str = ", ".join(parts)
    return f"{indicator} {tokens_str}"


def _format_duration(duration_ms: float | None) -> str:
    """Format duration in human-readable form."""
    if duration_ms is None:
        return ""

    if duration_ms < 1000:
        return f"{duration_ms:.0f}ms"
    elif duration_ms < 60000:
        return f"{duration_ms / 1000:.1f}s"
    else:
        mins = int(duration_ms // 60000)
        secs = (duration_ms % 60000) / 1000
        return f"{mins}m{secs:.0f}s"


def _format_status(span: SpanState) -> str:
    """Format status with color and icon."""
    if span.status == "running":
        return f"{Colors.YELLOW}{Icons.RUNNING}{Colors.RESET}"
    elif span.status == "done":
        duration = _format_duration(span.duration_ms)
        return f"{Colors.GREEN}{Icons.DONE}{Colors.RESET} {Colors.DIM}{duration}{Colors.RESET}"
    elif span.status == "failed":
        return f"{Colors.RED}{Icons.FAILED}{Colors.RESET}"
    else:
        return f"{Colors.DIM}?{Colors.RESET}"


def _get_node_icon(kind: NodeKind) -> str:
    """Get icon for node type."""
    if kind == NodeKind.AGENT_RUN:
        return Icons.AGENT
    elif kind == NodeKind.MODEL_CALL:
        return Icons.MODEL
    elif kind == NodeKind.TOOL_CALL:
        return Icons.TOOL
    else:
        return "•"


def _get_node_color(kind: NodeKind) -> str:
    """Get color for node type."""
    if kind == NodeKind.AGENT_RUN:
        return Colors.GREEN
    elif kind == NodeKind.MODEL_CALL:
        return Colors.BLUE
    elif kind == NodeKind.TOOL_CALL:
        return Colors.MAGENTA
    else:
        return Colors.WHITE


# ═══════════════════════════════════════════════════════════════════════════════
# Renderer State
# ═══════════════════════════════════════════════════════════════════════════════


@dataclass
class RenderState:
    """Tracks rendering state for incremental updates."""

    last_render_time: float = 0.0
    last_line_count: int = 0
    enabled: bool = True
    min_interval: float = 0.2  # Minimum seconds between renders

    # Track what we've shown to avoid redundant output
    shown_spans: set[str] = None

    def __post_init__(self):
        if self.shown_spans is None:
            self.shown_spans = set()


# Module-level render state
_render_state = RenderState()


# ═══════════════════════════════════════════════════════════════════════════════
# Tree Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _render_span_line(
    span: SpanState,
    prefix: str = "",
    is_last: bool = True,
) -> str:
    """Render a single span as a tree line."""
    # Branch character
    branch = Box.LAST if is_last else Box.BRANCH

    # Node icon and color
    icon = _get_node_icon(span.kind)
    color = _get_node_color(span.kind)

    # Name
    name = span.name or span.kind.value

    # Status
    status = _format_status(span)

    # Tokens
    tokens = _format_tokens(span.usage)

    # Build line
    line = f"{prefix}{branch} {icon} {color}{name}{Colors.RESET} {status}"
    if tokens:
        line += f" {Colors.DIM}[{tokens}]{Colors.RESET}"

    return line


def _render_tree(
    state: TraceState,
    parent_span_id: str | None = None,
    prefix: str = "",
) -> list[str]:
    """Recursively render spans as a tree."""
    lines = []

    # Find spans with this parent
    children = [s for s in state.spans.values() if s.parent_span_id == parent_span_id]

    # Sort by start time
    children.sort(key=lambda s: s.started_at)

    for i, span in enumerate(children):
        is_last = i == len(children) - 1

        # Render this span
        line = _render_span_line(span, prefix, is_last)
        lines.append(line)

        # Render children with updated prefix
        child_prefix = prefix + (Box.SPACE if is_last else Box.PIPE)
        child_lines = _render_tree(state, span.span_id, child_prefix)
        lines.extend(child_lines)

    return lines


# ═══════════════════════════════════════════════════════════════════════════════
# Box Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _render_box(
    state: TraceState,
    width: int = 60,
) -> list[str]:
    """Render trace state in a bordered box."""
    lines = []

    # Header
    active_count = len(state.active_spans())
    total_count = len(state.spans)

    if active_count > 0:
        header = f" Agent Trace ({active_count} active, {total_count} total) "
    else:
        header = f" Agent Trace ({total_count} spans) "

    # Top border with header
    padding = width - len(header) - 2
    left_pad = padding // 2
    right_pad = padding - left_pad
    top = f"{Box.TL}{Box.H * left_pad}{Colors.BOLD}{header}{Colors.RESET}{Box.H * right_pad}{Box.TR}"
    lines.append(top)

    # Tree content
    tree_lines = _render_tree(state)
    for tree_line in tree_lines:
        # Pad to width
        padding = max(0, width - 4)  # Leave room for borders
        lines.append(f"{Box.V} {tree_line:<{padding}} {Box.V}")

    # Summary line
    if state.total_output_tokens > 0 or state.total_input_tokens > 0:
        pending = len(state.pending_reconciliation)
        summary_parts = []
        if state.total_input_tokens:
            summary_parts.append(f"{state.total_input_tokens} in")
        if state.total_output_tokens:
            summary_parts.append(f"{state.total_output_tokens} out")
        if pending:
            summary_parts.append(f"{pending} pending reconcile")

        summary = " │ ".join(summary_parts)
        lines.append(f"{Box.V} {Colors.DIM}Σ {summary}{Colors.RESET}")

    # Bottom border
    bottom = f"{Box.BL}{Box.H * (width - 2)}{Box.BR}"
    lines.append(bottom)

    return lines


# ═══════════════════════════════════════════════════════════════════════════════
# Compact Inline Rendering
# ═══════════════════════════════════════════════════════════════════════════════


def _render_inline(state: TraceState) -> str:
    """Render a compact single-line status for inline display."""
    active = state.active_spans()
    if not active:
        return ""

    parts = []
    for span in active:
        icon = _get_node_icon(span.kind)
        name = span.name or span.kind.value
        tokens = _format_tokens(span.usage)

        if tokens:
            parts.append(f"{icon} {name} [{tokens}]")
        else:
            parts.append(f"{icon} {name}")

    return f"{Colors.DIM}trace: {' → '.join(parts)}{Colors.RESET}"


# ═══════════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════════


def render_trace(
    state: TraceState,
    mode: str = "tree",
    output: TextIO | None = None,
    width: int = 60,
) -> str:
    """Render trace state to string.

    Args:
        state: The TraceState to render
        mode: "tree" for box view, "inline" for compact single line
        output: Optional file to write to (default: return string)
        width: Box width for tree mode

    Returns:
        Rendered string
    """
    if mode == "inline":
        result = _render_inline(state)
    else:
        lines = _render_box(state, width)
        result = "\n".join(lines)

    if output:
        output.write(result)
        if not result.endswith("\n"):
            output.write("\n")
        output.flush()

    return result


def should_render(state: TraceState, force: bool = False) -> bool:
    """Check if we should render (throttling)."""
    global _render_state

    if not _render_state.enabled:
        return False

    if force:
        return True

    now = time.time()
    if now - _render_state.last_render_time < _render_state.min_interval:
        return False

    # Check if state has changed
    current_spans = set(state.spans.keys())
    if current_spans == _render_state.shown_spans:
        # Check if any status changed
        pass  # TODO: more sophisticated change detection

    return True


def clear_previous_render() -> None:
    """Clear previous render output from terminal."""
    global _render_state

    if _render_state.last_line_count > 0 and sys.stdout.isatty():
        # Move cursor up and clear lines
        sys.stdout.write(f"\033[{_render_state.last_line_count}A\033[J")
        sys.stdout.flush()
        _render_state.last_line_count = 0


def render_live(
    state: TraceState,
    mode: str = "tree",
    force: bool = False,
) -> None:
    """Render trace state to stdout with live update support.

    Handles clearing previous output and throttling.
    """
    global _render_state

    if not should_render(state, force):
        return

    # Clear previous output
    clear_previous_render()

    # Render new output
    output = render_trace(state, mode)
    if output:
        print(output)
        _render_state.last_line_count = output.count("\n") + 1
        _render_state.last_render_time = time.time()
        _render_state.shown_spans = set(state.spans.keys())


def set_render_enabled(enabled: bool) -> None:
    """Enable or disable rendering."""
    global _render_state
    _render_state.enabled = enabled


def is_render_enabled() -> bool:
    """Check if rendering is enabled."""
    return _render_state.enabled
