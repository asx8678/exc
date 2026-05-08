"""
Message queue system for decoupling Rich console output from renderers.

This allows interactive mode to consume messages and render them appropriately.
"""

import asyncio
import logging
import queue
import threading
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from rich.text import Text

logger = logging.getLogger(__name__)


class MessageType(Enum):
    """Types of messages that can be sent through the queue."""

    # Basic content types
    INFO = "info"
    SUCCESS = "success"
    WARNING = "warning"
    ERROR = "error"
    DIVIDER = "divider"

    # Tool-specific types
    TOOL_OUTPUT = "tool_output"
    COMMAND_OUTPUT = "command_output"
    FILE_OPERATION = "file_operation"

    # Agent-specific types
    AGENT_REASONING = "agent_reasoning"
    PLANNED_NEXT_STEPS = "planned_next_steps"
    AGENT_RESPONSE = "agent_response"
    AGENT_STATUS = "agent_status"

    # Human interaction types
    HUMAN_INPUT_REQUEST = "human_input_request"

    # System types
    SYSTEM = "system"
    DEBUG = "debug"


@dataclass
class UIMessage:
    """A message to be displayed in the UI."""

    type: MessageType
    content: str | Text | Any  # Can be Rich Text, Table, Markdown, etc.
    timestamp: datetime = None
    metadata: dict[str, Any] = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = datetime.now(timezone.utc)
        if self.metadata is None:
            self.metadata = {}


class MessageQueue:
    """Thread-safe message queue for UI messages."""

    def __init__(self, maxsize: int = 1000):
        self._maxsize = maxsize  # Used by get_buffered_messages swap-and-clear
        self._queue = queue.Queue(maxsize=maxsize)
        self._async_queue = None  # Will be created when needed
        self._async_queue_maxsize = maxsize
        self._listeners = []
        self._running = False
        self._thread = None
        self._startup_buffer = deque(
            maxlen=maxsize
        )  # Buffer messages before any renderer starts
        self._has_active_renderer = False
        self._event_loop = None  # Store reference to the event loop
        self._prompt_responses = {}  # Store responses to human input requests
        self._prompt_events = {}  # threading.Event per prompt_id
        self._prompt_id_counter = 0  # Counter for unique prompt IDs

        # Condition variable for signaling when queue is empty (all messages rendered)
        # This eliminates the need for polling with asyncio.sleep(0.1)
        self._queue_condition = threading.Condition()
        self._pending_count = 0  # Track messages in flight

    def start(self):
        """Start the queue processing."""
        if self._running:
            return

        self._running = True
        self._thread = threading.Thread(target=self._process_messages, daemon=True)
        self._thread.start()

    def get_buffered_messages(self):
        """Get all currently buffered messages without waiting.

        Uses swap-and-clear pattern for atomic buffer retrieval and reset.
        """
        # Swap-and-clear: atomically swap buffer with new empty one
        old_buffer = self._startup_buffer
        self._startup_buffer = deque(maxlen=self._maxsize)
        messages = list(old_buffer)

        # Then get any queued messages
        while True:
            try:
                message = self._queue.get_nowait()
                messages.append(message)
            except queue.Empty:
                break
        return messages

    def stop(self):
        """Stop the queue processing."""
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)

    def emit(self, message: UIMessage):
        """Emit a message to the queue."""
        # If no renderer is active yet, buffer the message for startup
        if not self._has_active_renderer:
            self._startup_buffer.append(message)
            return

        try:
            with self._queue_condition:
                self._pending_count += 1
                self._queue.put_nowait(message)
        except queue.Full:
            # Drop oldest message to make room
            try:
                with self._queue_condition:
                    dropped = self._queue.get_nowait()
                    if dropped is not None:
                        self._pending_count -= 1
                    self._queue.put_nowait(message)
                    self._pending_count += 1
            except queue.Empty:
                pass

    def emit_simple(self, message_type: MessageType, content: Any, **metadata):
        """Emit a simple message with just type and content."""
        msg = UIMessage(type=message_type, content=content, metadata=metadata)
        self.emit(msg)

    def get_nowait(self) -> UIMessage | None:
        """Get a message without blocking."""
        try:
            return self._queue.get_nowait()
        except queue.Empty:
            return None

    async def get_async(self) -> UIMessage:
        """Get a message asynchronously."""
        # Lazy initialization of async queue and store event loop reference
        if self._async_queue is None:
            self._async_queue = asyncio.Queue(maxsize=self._async_queue_maxsize)
            self._event_loop = asyncio.get_running_loop()
        return await self._async_queue.get()

    def _process_messages(self):
        """Process messages from sync to async queue."""
        while self._running:
            try:
                message = self._queue.get(timeout=0.1)

                # Try to put in async queue if we have an event loop reference
                if self._event_loop is not None and self._async_queue is not None:
                    # Use thread-safe call to put message in async queue
                    # Create a bound method to avoid closure issues
                    try:
                        self._event_loop.call_soon_threadsafe(
                            self._async_queue.put_nowait, message
                        )
                    except Exception as e:
                        logger.debug("Failed to enqueue message to async queue: %s", e)

                # Notify listeners immediately for sync processing
                for listener in self._listeners:
                    try:
                        listener(message)
                    except Exception as e:
                        logger.debug("Listener error in message queue: %s", e)

                # Signal that we've processed a message - decrement pending and notify
                with self._queue_condition:
                    self._pending_count -= 1
                    if self._pending_count <= 0:
                        self._pending_count = 0
                        self._queue_condition.notify_all()

            except queue.Empty:
                continue

    def add_listener(self, callback):
        """Add a listener for messages (for direct sync consumption)."""
        self._listeners.append(callback)
        # Mark that we have an active renderer
        self._has_active_renderer = True

    def remove_listener(self, callback):
        """Remove a listener."""
        if callback in self._listeners:
            self._listeners.remove(callback)
        # If no more listeners, mark as no active renderer
        if not self._listeners:
            self._has_active_renderer = False

    def mark_renderer_active(self):
        """Mark that a renderer is now active and consuming messages."""
        self._has_active_renderer = True

    def mark_renderer_inactive(self):
        """Mark that no renderer is currently active."""
        self._has_active_renderer = False

    def wait_for_empty(self, timeout: float | None = None) -> bool:
        """Wait for all pending messages to be processed.

        Uses a condition variable to efficiently wait until the queue is empty
        and all messages have been rendered. This is event-driven (no polling),
        unlike the previous asyncio.sleep(0.1) approach.

        Args:
            timeout: Maximum time to wait in seconds. If None, wait indefinitely.
                    Note: A small timeout (e.g., 0.5s) is recommended to prevent
                    indefinite blocking if message processing is stuck.

        Returns:
            True if queue became empty, False if timeout occurred.
        """
        with self._queue_condition:
            # Check if queue is already empty
            if self._pending_count <= 0 and self._queue.empty():
                return True

            # Wait for condition to be signaled (queue becomes empty)
            signaled = self._queue_condition.wait(timeout=timeout)
            return signaled

    def create_prompt_request(self, prompt_text: str) -> str:
        """Create a human input request and return its unique ID."""
        self._prompt_id_counter += 1
        prompt_id = f"prompt_{self._prompt_id_counter}"

        # Create event for this prompt
        self._prompt_events[prompt_id] = threading.Event()

        # Emit the human input request message
        message = UIMessage(
            type=MessageType.HUMAN_INPUT_REQUEST,
            content=prompt_text,
            metadata={"prompt_id": prompt_id},
        )
        self.emit(message)

        return prompt_id

    def wait_for_prompt_response(self, prompt_id: str, timeout: float = None) -> str:
        """Wait for a response to a human input request."""
        # If response is already available, return immediately
        if prompt_id in self._prompt_responses:
            self._prompt_events.pop(prompt_id, None)
            return self._prompt_responses.pop(prompt_id)

        event = self._prompt_events.get(prompt_id)
        if event is None:
            # Fallback: create event if not already present
            event = threading.Event()
            self._prompt_events[prompt_id] = event

        signaled = event.wait(timeout=timeout)

        # Clean up the event
        self._prompt_events.pop(prompt_id, None)

        if not signaled:
            raise TimeoutError(f"No response for prompt {prompt_id} within {timeout}s")

        return self._prompt_responses.pop(prompt_id)

    def provide_prompt_response(self, prompt_id: str, response: str):
        """Provide a response to a human input request."""
        self._prompt_responses[prompt_id] = response
        event = self._prompt_events.get(prompt_id)
        if event is not None:
            event.set()


# Global message queue instance
_global_queue: MessageQueue | None = None
_queue_lock = threading.Lock()


def get_global_queue() -> MessageQueue:
    """Get or create the global message queue."""
    global _global_queue

    with _queue_lock:
        if _global_queue is None:
            _global_queue = MessageQueue()
            _global_queue.start()

    return _global_queue


def reset_global_queue_for_tests() -> None:
    """Reset the global message queue singleton for test isolation.

    Stops the existing queue (if any) and clears the singleton so the next
    get_global_queue() call creates a fresh instance.
    """
    global _global_queue
    with _queue_lock:
        if _global_queue is not None:
            try:
                _global_queue.stop()
            except Exception:
                pass  # Best effort cleanup
            _global_queue = None


def get_buffered_startup_messages():
    """Get any messages that were buffered before renderers started."""
    queue = get_global_queue()
    # Only return startup buffer messages, don't clear them yet
    messages = list(queue._startup_buffer)
    return messages


def emit_message(message_type: MessageType, content: Any, **metadata):
    """Convenience function to emit a message to the global queue."""
    queue = get_global_queue()
    queue.emit_simple(message_type, content, **metadata)


def emit_info(content: Any, **metadata):
    """Emit an info message."""
    emit_message(MessageType.INFO, content, **metadata)


def emit_success(content: Any, **metadata):
    """Emit a success message."""
    emit_message(MessageType.SUCCESS, content, **metadata)


def emit_warning(content: Any, **metadata):
    """Emit a warning message."""
    emit_message(MessageType.WARNING, content, **metadata)


def emit_error(content: Any, **metadata):
    """Emit an error message."""
    emit_message(MessageType.ERROR, content, **metadata)


def emit_tool_output(content: Any, tool_name: str = None, **metadata):
    """Emit tool output."""
    if tool_name:
        metadata["tool_name"] = tool_name
    emit_message(MessageType.TOOL_OUTPUT, content, **metadata)


def emit_command_output(content: Any, command: str = None, **metadata):
    """Emit command output."""
    if command:
        metadata["command"] = command
    emit_message(MessageType.COMMAND_OUTPUT, content, **metadata)


def emit_agent_reasoning(content: Any, **metadata):
    """Emit agent reasoning."""
    emit_message(MessageType.AGENT_REASONING, content, **metadata)


def emit_planned_next_steps(content: Any, **metadata):
    """Emit planned_next_steps"""
    emit_message(MessageType.PLANNED_NEXT_STEPS, content, **metadata)


def emit_agent_response(content: Any, **metadata):
    """Emit agent_response"""
    emit_message(MessageType.AGENT_RESPONSE, content, **metadata)


def emit_system_message(content: Any, **metadata):
    """Emit a system message."""
    emit_message(MessageType.SYSTEM, content, **metadata)


def emit_divider(content: str = "─" * 100 + "\n", **metadata):
    """Emit a divider line"""
    # TUI mode has been removed, always emit dividers
    emit_message(MessageType.DIVIDER, content, **metadata)


def emit_prompt(prompt_text: str, timeout: float = None) -> str:
    """Emit a human input request and wait for response.

    Uses safe_input for cross-platform compatibility, especially on Windows
    where raw input() can fail after prompt_toolkit Applications.
    """
    from code_puppy.command_line.utils import safe_input
    from code_puppy.messaging import emit_info

    emit_info(prompt_text)

    # Use safe_input which resets Windows console state before reading
    response = safe_input(">>> ")
    return response


def provide_prompt_response(prompt_id: str, response: str):
    """Provide a response to a human input request."""
    queue = get_global_queue()
    queue.provide_prompt_response(prompt_id, response)


async def wait_for_messages_rendered(timeout: float = 0.5) -> bool:
    """Async-friendly wrapper to wait for all messages to be rendered.

    This function uses the condition variable in MessageQueue to efficiently
    wait until all pending messages have been processed, instead of polling
    with asyncio.sleep().

    The condition variable is signaled by the message processing thread when
    the queue becomes empty (all messages have been delivered to renderers).

    Args:
        timeout: Maximum time to wait in seconds. Default 0.5s to prevent
                indefinite blocking. Increase if rendering complex output.

    Returns:
        True if all messages were rendered, False if timeout occurred.
    """
    queue = get_global_queue()
    # Use asyncio.to_thread to call the sync wait_for_empty method
    # This allows the sync condition variable wait to run in a thread pool
    # without blocking the event loop
    import asyncio

    return await asyncio.to_thread(queue.wait_for_empty, timeout)
