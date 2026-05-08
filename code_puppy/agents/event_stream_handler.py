"""Event stream handler for processing streaming events from agent runs."""

import asyncio
import importlib.util
import logging
from collections.abc import AsyncIterable
from typing import Any

from pydantic_ai import PartDeltaEvent, PartEndEvent, PartStartEvent, RunContext
from pydantic_ai.messages import (
    TextPart,
    TextPartDelta,
    ThinkingPart,
    ThinkingPartDelta,
    ToolCallPart,
    ToolCallPartDelta,
)
from rich.console import Console
from rich.markup import escape
from rich.text import Text

from code_puppy.agents.stream_event_normalizer import normalize_stream_event
from code_puppy.config import get_banner_color, get_subagent_verbose
from code_puppy.messaging.spinner import pause_all_spinners, resume_all_spinners
from code_puppy.tools.subagent_context import is_subagent

logger = logging.getLogger(__name__)

# Module-level buffer for batching stream events
_pending_stream_events: list[tuple[str, Any, Any]] = []
_STREAM_FLUSH_INTERVAL = 50

# Module-level state for stream-to-render coordination
# Tracks whether text was streamed AND how many terminal lines were printed
_streamed_line_count: int = 0  # Lines printed during streaming (including banner)
_did_stream_text: bool = False  # Whether text content was streamed


def get_stream_state() -> tuple[bool, int]:
    """Return (did_stream, line_count) and reset state.

    This is used to coordinate between the streaming handler and the
    message renderer. The streaming handler tracks how many lines were
    printed, and the renderer uses this to erase them before re-rendering
    as markdown.

    Returns:
        Tuple of (whether text was streamed, number of terminal lines printed)
    """
    global _did_stream_text, _streamed_line_count
    result = (_did_stream_text, _streamed_line_count)
    _did_stream_text = False
    _streamed_line_count = 0
    return result


def _reset_stream_state() -> None:
    """Reset the stream state at the start of a new handler invocation."""
    global _did_stream_text, _streamed_line_count
    _did_stream_text = False
    _streamed_line_count = 0


# Track active flush tasks to prevent garbage collection and ensure completion
_active_flush_tasks: set[asyncio.Task] = set()

# Flush text-part delta buffer when it exceeds this many characters.
# Larger than the TUI's 20-char threshold because terminal ANSI writes
# benefit from batching; TUI updates a widget which has different perf
# characteristics.
_TEXT_FLUSH_CHAR_THRESHOLD = 80


def _fire_stream_event(event_type: str, event_data: Any) -> None:
    """Fire a stream event callback asynchronously (non-blocking) with batching.

    Events are normalized to a unified schema and batched to reduce task
    creation overhead. The batch is flushed when 'part_end' event is received
    or when batch size reaches the threshold.

    Args:
        event_type: Type of the event (e.g., 'part_start', 'part_delta', 'part_end')
        event_data: Data associated with the event (will be normalized)
    """
    global _pending_stream_events

    try:
        # Check if callbacks module is available without importing
        if importlib.util.find_spec("code_puppy.callbacks") is None:
            raise ImportError("callbacks module not available")
        from code_puppy.messaging import get_session_context

        agent_session_id = get_session_context()

        # Normalize event data to unified schema for consistent processing
        # by downstream consumers like Agent Trace
        if isinstance(event_data, dict):
            normalized_data = normalize_stream_event(event_type, event_data)
        else:
            # Fallback for non-dict event data (shouldn't happen in practice)
            normalized_data = {
                "content_delta": str(event_data) if event_data else None,
                "args_delta": None,
                "tool_name": None,
                "tool_name_delta": None,
                "part_kind": "unknown",
                "index": -1,
                "raw": {"_original": event_data},
            }

        _pending_stream_events.append((event_type, normalized_data, agent_session_id))

        # Flush on part_end or when batch threshold reached
        if (
            event_type == "part_end"
            or len(_pending_stream_events) >= _STREAM_FLUSH_INTERVAL
        ):
            batch = _pending_stream_events.copy()
            _pending_stream_events.clear()
            task = asyncio.create_task(_flush_stream_events(batch))
            _active_flush_tasks.add(task)
            task.add_done_callback(_active_flush_tasks.discard)
    except ImportError:
        logger.debug("callbacks or messaging module not available for stream event")
    except Exception as e:
        logger.debug(f"Error firing stream event callback: {e}")


async def _flush_stream_events(batch: list) -> None:
    """Flush a batch of stream events to the callbacks.

    Args:
        batch: List of (event_type, event_data, session_id) tuples to process.
    """
    from code_puppy import callbacks

    for event_type, event_data, session_id in batch:
        try:
            await callbacks.on_stream_event(event_type, event_data, session_id)
        except Exception as e:
            logger.debug(f"Error flushing stream event: {e}")


async def _drain_pending_stream_events() -> None:
    """Drain any pending stream events before handler exits.

    Ensures that any batched events are delivered before the handler completes.
    Also awaits any in-flight flush tasks to prevent event loss on shutdown.
    """
    global _pending_stream_events

    if _pending_stream_events:
        batch = _pending_stream_events.copy()
        _pending_stream_events.clear()
        await _flush_stream_events(batch)

    # Await any in-flight flush tasks
    if _active_flush_tasks:
        await asyncio.gather(*_active_flush_tasks, return_exceptions=True)
        _active_flush_tasks.clear()


# Module-level console for streaming output
# Set via set_streaming_console() to share console with spinner
_streaming_console: Console | None = None


def set_streaming_console(console: Console | None) -> None:
    """Set the console used for streaming output.

    Sharing a console with the spinner keeps spinner pause/resume
    coordination working during thinking-part and tool-call output.
    Text parts stream as escaped plain chunks (no Rich Live wrapper)
    to avoid the cascading re-render bug.

    Args:
        console: The Rich console to use, or None to use a fallback.
    """
    global _streaming_console
    _streaming_console = console


def get_streaming_console() -> Console:
    """Get the console for streaming output.

    Returns the configured console or creates a fallback Console.
    """
    if _streaming_console is not None:
        return _streaming_console
    return Console()


def _should_suppress_output() -> bool:
    """Check if sub-agent output should be suppressed.

    Returns:
        True if we're in a sub-agent context and verbose mode is disabled.
    """
    return is_subagent() and not get_subagent_verbose()


async def event_stream_handler(ctx: RunContext, events: AsyncIterable[Any]) -> None:
    """Handle streaming events from the agent run.

    This function processes streaming events and emits TextPart, ThinkingPart,
    and ToolCallPart content with styled banners/tokens as they stream in.

    Text parts are streamed as escaped plain text (not live markdown) to avoid
    Rich Live re-render duplication that occurs with long content. The cascading
    duplication bug happened because Rich Live with
    vertical_overflow="visible" re-emits the entire buffer on every refresh when
    content exceeds terminal height. Now we use list-buffered delta streaming with
    flush-on-newline/80-chars, similar to the TUI approach in stream_renderer.py.
    Final markdown formatting happens elsewhere via the message bus (AgentResponseMessage).
    ThinkingPart and ToolCallPart streaming behavior is unchanged.

    Args:
        ctx: The run context.
        events: Async iterable of streaming events (PartStartEvent, PartDeltaEvent, etc.).
    """
    global _did_stream_text, _streamed_line_count

    # Reset stream state at the start of each handler invocation
    _reset_stream_state()

    try:
        # If we're in a sub-agent and verbose mode is disabled, silently consume events
        if _should_suppress_output():
            async for _ in events:
                pass  # Just consume events without rendering
            return

        # Use the module-level console (set via set_streaming_console)
        console = get_streaming_console()

        # Track which part indices we're currently streaming (for Text/Thinking/Tool parts)
        streaming_parts: set[int] = set()
        thinking_parts: set[int] = (
            set()
        )  # Track which parts are thinking (for dim style)
        text_parts: set[int] = set()  # Track which parts are text
        tool_parts: set[int] = set()  # Track which parts are tool calls
        banner_printed: set[int] = set()  # Track if banner was already printed
        token_count: dict[int, int] = {}  # Track token count per text/tool part
        tool_names: dict[int, str] = {}  # Track tool name per tool part index
        did_stream_anything = False  # Track if we streamed any content

        # Text part streaming state: list-buffered for O(1) append, flush on newline
        text_buffers: dict[int, list[str]] = {}  # Accumulated content chunks per index

        async def _print_thinking_banner() -> None:
            """Print the THINKING banner with spinner pause and line clear."""
            nonlocal did_stream_anything

            pause_all_spinners()
            await asyncio.sleep(0.1)  # Delay to let spinner fully clear
            # Clear line and print newline before banner
            console.print(" " * 50, end="\r")
            console.print()  # Newline before banner
            # Bold banner with configurable color and lightning bolt
            thinking_color = get_banner_color("thinking")
            console.print(
                Text.from_markup(
                    f"[bold white on {thinking_color}] THINKING [/bold white on {thinking_color}] [dim]\\u26a1 "
                ),
                end="",
            )
            did_stream_anything = True

        async def _print_response_banner() -> None:
            """Print the AGENT RESPONSE banner with spinner pause and line clear."""
            nonlocal did_stream_anything
            global _did_stream_text, _streamed_line_count

            pause_all_spinners()
            await asyncio.sleep(0.1)  # Delay to let spinner fully clear
            # Clear line and print newline before banner
            console.print(" " * 50, end="\r")
            console.print()  # Newline before banner
            response_color = get_banner_color("agent_response")
            console.print(
                Text.from_markup(
                    f"[bold white on {response_color}] AGENT RESPONSE [/bold white on {response_color}]"
                )
            )
            did_stream_anything = True
            # Track that we streamed content and count lines
            # Banner takes 2 lines: the blank line before it + the banner itself
            _did_stream_text = True
            _streamed_line_count += 2

        async for event in events:
            # PartStartEvent - register the part but defer banner until content arrives
            if isinstance(event, PartStartEvent):
                # Fire stream event callback for part_start
                _fire_stream_event(
                    "part_start",
                    {
                        "index": event.index,
                        "part_type": type(event.part).__name__,
                        "part": event.part,
                    },
                )

                part = event.part
                if isinstance(part, ThinkingPart):
                    streaming_parts.add(event.index)
                    thinking_parts.add(event.index)
                    # If there's initial content, print banner + content now
                    if part.content and part.content.strip():
                        await _print_thinking_banner()
                        escaped = escape(part.content)
                        console.print(f"[dim]{escaped}[/dim]", end="")
                        banner_printed.add(event.index)
                elif isinstance(part, TextPart):
                    streaming_parts.add(event.index)
                    text_parts.add(event.index)
                    # Initialize text buffer for this text part (list for O(1) append)
                    text_buffers[event.index] = []
                    # Handle initial content if present
                    if part.content and part.content.strip():
                        await _print_response_banner()
                        banner_printed.add(event.index)
                        # Immediately print initial content as plain text
                        console.print(part.content, end="", markup=False)
                elif isinstance(part, ToolCallPart):
                    streaming_parts.add(event.index)
                    tool_parts.add(event.index)
                    token_count[event.index] = 0  # Initialize token counter
                    # Capture tool name from the start event
                    tool_names[event.index] = part.tool_name or ""
                    # Track tool name for display
                    banner_printed.add(
                        event.index
                    )  # Use banner_printed to track if we've shown tool info

            # PartDeltaEvent - stream the content as it arrives
            elif isinstance(event, PartDeltaEvent):
                # Fire stream event callback for part_delta
                _fire_stream_event(
                    "part_delta",
                    {
                        "index": event.index,
                        "delta_type": type(event.delta).__name__,
                        "delta": event.delta,
                    },
                )

                if event.index in streaming_parts:
                    delta = event.delta
                    if isinstance(delta, (TextPartDelta, ThinkingPartDelta)):
                        if delta.content_delta:
                            # For text parts, stream as plain escaped text (no Live)
                            if event.index in text_parts:
                                # Print banner on first content
                                if event.index not in banner_printed:
                                    await _print_response_banner()
                                    banner_printed.add(event.index)

                                # Append content to list buffer
                                text_buffers[event.index].append(delta.content_delta)
                                # Flush on newline or when buffer exceeds threshold
                                buf = "".join(text_buffers[event.index])
                                if "\n" in buf or len(buf) > _TEXT_FLUSH_CHAR_THRESHOLD:
                                    console.print(buf, end="", markup=False)
                                    # Count newlines in the flushed buffer
                                    _streamed_line_count += buf.count("\n")
                                    text_buffers[event.index] = []
                            else:
                                # For thinking parts, stream immediately (dim)
                                if event.index not in banner_printed:
                                    await _print_thinking_banner()
                                    banner_printed.add(event.index)
                                escaped = escape(delta.content_delta)
                                console.print(f"[dim]{escaped}[/dim]", end="")
                    elif isinstance(delta, ToolCallPartDelta):
                        # For tool calls, estimate tokens from args_delta content
                        # args_delta contains the streaming JSON arguments
                        args_delta = getattr(delta, "args_delta", "") or ""
                        if args_delta:
                            # Rough estimate: 4 chars ≈ 1 token (same heuristic as subagent_stream_handler)
                            estimated_tokens = max(1, len(args_delta) // 4)
                            token_count[event.index] += estimated_tokens
                        else:
                            # Even empty deltas count as activity
                            token_count[event.index] += 1

                        # Update tool name if delta provides more of it
                        tool_name_delta = getattr(delta, "tool_name_delta", "") or ""
                        if tool_name_delta:
                            tool_names[event.index] = (
                                tool_names.get(event.index, "") + tool_name_delta
                            )

                        # Use stored tool name for display
                        tool_name = tool_names.get(event.index, "")
                        count = token_count[event.index]
                        # Display with tool wrench icon and tool name
                        if tool_name:
                            console.print(
                                f"  \U0001f527 Calling {tool_name}... {count} token(s)   ",
                                end="\r",
                            )
                        else:
                            console.print(
                                f"  \U0001f527 Calling tool... {count} token(s)   ",
                                end="\r",
                            )

            # PartEndEvent - finish the streaming with a newline
            elif isinstance(event, PartEndEvent):
                # Fire stream event callback for part_end
                _fire_stream_event(
                    "part_end",
                    {
                        "index": event.index,
                        "next_part_kind": getattr(event, "next_part_kind", None),
                    },
                )

                if event.index in streaming_parts:
                    # For text parts, flush any remaining buffered content and add newline
                    if event.index in text_parts:
                        # Flush any remaining buffered content before cleanup
                        if event.index in text_buffers:
                            remaining = text_buffers.pop(event.index, None)
                            if remaining:
                                buf = "".join(remaining)
                                if buf:
                                    console.print(buf, end="", markup=False)
                                    # Count remaining newlines in the final buffer
                                    _streamed_line_count += buf.count("\n")
                        # Print trailing newline only if banner was printed (i.e., we had content)
                        if event.index in banner_printed:
                            console.print()  # Final newline after text streaming
                            _streamed_line_count += 1  # Count the final newline
                    # For tool parts, clear the chunk counter line
                    elif event.index in tool_parts:
                        # Clear the chunk counter line by printing spaces and returning
                        console.print(" " * 50, end="\r")
                    # For thinking parts, just print newline
                    elif event.index in banner_printed:
                        console.print()  # Final newline after streaming

                    # Clean up token count and tool names
                    token_count.pop(event.index, None)
                    tool_names.pop(event.index, None)
                    # Clean up all tracking sets
                    streaming_parts.discard(event.index)
                    thinking_parts.discard(event.index)
                    text_parts.discard(event.index)
                    tool_parts.discard(event.index)
                    banner_printed.discard(event.index)

                    # Resume spinner if next part is NOT text/thinking/tool (avoid race condition)
                    # If next part is None or handled differently, it's safe to resume
                    # Note: spinner itself handles blank line before appearing
                    next_kind = getattr(event, "next_part_kind", None)
                    if next_kind not in ("text", "thinking", "tool-call"):
                        resume_all_spinners()

    finally:
        # Force cursor visibility restoration (defensive hygiene)
        try:
            console.show_cursor(True)
        except Exception:
            pass

    # Spinner is resumed in PartEndEvent when appropriate (based on next_part_kind)
    # Drain any remaining buffered stream events before handler exits
    await _drain_pending_stream_events()
