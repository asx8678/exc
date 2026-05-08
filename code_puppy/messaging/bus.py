"""MessageBus - Central coordinator for bidirectional Agent <-> UI communication.

The MessageBus manages two queues:
- outgoing: Messages flow from Agent → UI (AnyMessage)
- incoming: Commands flow from UI → Agent (AnyCommand)

It also handles request/response correlation for user interactions:
1. Agent calls request_input() which emits a UserInputRequest and waits
2. UI receives the request and displays a prompt
3. User provides input, UI calls provide_response() with UserInputResponse
4. MessageBus matches the response to the waiting request via prompt_id
5. Agent's request_input() returns with the user's value

    ┌─────────────────────────────────────────────────────────────┐
    │ MessageBus │
    │ ┌─────────────┐ ┌─────────────┐ │
    │ │ outgoing │ Messages (Agent→UI) │ incoming │ │
    │ │ Queue │ ───────────────────> │ Queue │ │
    │ │ [AnyMessage]│ │ [AnyCommand]│ │
    │ └─────────────┘ └─────────────┘ │
    │ ↑ │ │
    │ │ ↓ │
    │ emit() provide_response() │
    │ emit_text() │
    │ request_input() ─────────────────────────────────────────│
    │ ↑ (waits for matching response) │
    │ │ │
    │ ┌──────┴──────┐ │
    │ │ pending │ prompt_id → Future │
    │ │ requests │ │
    │ └─────────────┘ │
    └─────────────────────────────────────────────────────────────┘
"""

import asyncio
import threading
from collections import deque
from collections.abc import Callable
from typing import Any
from uuid import uuid4

from code_puppy.config import get_bus_request_timeout_seconds

from .commands import (
    AnyCommand,
    ConfirmationResponse,
    SelectionResponse,
    UserInputResponse,
)
from .messages import (
    AnyMessage,
    ConfirmationRequest,
    MessageCategory,
    MessageLevel,
    SelectionRequest,
    TextMessage,
    UserInputRequest,
)


class MessageBus:
    """Central coordinator for bidirectional Agent <-> UI communication.

    Thread-safe message bus that works in both sync and async contexts.
    Uses asyncio.Queue for zero-latency async operation with call_soon_threadsafe for cross-thread puts.
    Manages outgoing messages, incoming commands, and request/response correlation.
    """

    __slots__ = (
        "_maxsize",
        "_lock",
        "_outgoing",
        "_incoming",
        "_event_loop",
        "_startup_buffer",
        "_has_active_renderer",
        "_renderer_event",
        "_pending_requests",
        "_current_session_id",
        "_loop_thread_id",
        "_wakeup_callback",
    )

    def __init__(self, maxsize: int = 1000) -> None:
        """Initialize the MessageBus.

        Args:
            maxsize: Maximum queue size before blocking/dropping.
        """
        self._maxsize = maxsize
        self._lock = threading.Lock()

        # asyncio.Queue for zero-latency async consumption.
        # emit() / provide_response() use call_soon_threadsafe when the loop
        # is known so that cross-thread puts are safe.
        self._outgoing: asyncio.Queue[AnyMessage] = asyncio.Queue(maxsize=maxsize)
        self._incoming: asyncio.Queue[AnyCommand] = asyncio.Queue(maxsize=maxsize)

        # Event loop reference – set lazily the first time an async method
        # runs, then reused for call_soon_threadsafe cross-thread puts.
        self._event_loop: asyncio.AbstractEventLoop | None = None

        # Startup buffering: deque with maxlen for O(1) append + auto-eviction
        self._startup_buffer: deque[AnyMessage] = deque(maxlen=self._maxsize)
        self._has_active_renderer = False

        # Lock-free fast path: Event is set when renderer is active.
        # Used in emit() to avoid acquiring lock when no subscribers.
        self._renderer_event = threading.Event()

        # Request/Response correlation: prompt_id → Future (for async usage)
        self._pending_requests: dict[str, asyncio.Future[Any]] = {}

        # Session context for multi-agent tracking
        self._current_session_id: str | None = None

        # Cache thread ID of the event loop for fast comparison in emit()
        self._loop_thread_id: int | None = None

        # Wakeup callback for renderer notification
        self._wakeup_callback: Callable[[], None] | None = None

    def register_wakeup_callback(self, callback: Callable[[], None] | None) -> None:
        """Register a callback to be called when new messages are emitted.

        This allows the renderer to efficiently wake up its thread when
        new messages arrive, instead of polling.

        Args:
            callback: Function to call when a message is emitted, or None to clear.
        """
        with self._lock:
            self._wakeup_callback = callback

    # =========================================================================
    # Outgoing Messages (Agent → UI)
    # =========================================================================

    def _emit_under_lock(self, message: AnyMessage) -> None:
        """Internal: emit a message with lock already held.

        This method assumes the caller has already acquired self._lock.
        It performs the actual message tagging and delivery logic.

        Args:
            message: The message to emit.
        """
        if message.session_id is None and self._current_session_id is not None:
            message.session_id = self._current_session_id

        # Double-check renderer status (could have changed)
        if not self._has_active_renderer:
            self._startup_buffer.append(message)
            # deque with maxlen handles eviction automatically (O(1))
            return

        # Thread-safe put: if already on the event loop thread, call
        # directly to ensure immediate delivery (avoids deferred put that
        # could cause get_message_nowait to miss the message). For true
        # cross-thread calls, use call_soon_threadsafe.
        if self._event_loop is not None:
            # Fast path: compare thread IDs instead of calling get_running_loop()
            if threading.current_thread().ident == self._loop_thread_id:
                # Already on the event loop thread - put directly
                self._put_to_outgoing(message)
            else:
                try:
                    self._event_loop.call_soon_threadsafe(
                        self._put_to_outgoing, message
                    )
                except RuntimeError:
                    # Loop closed – fall back to direct put
                    self._put_to_outgoing(message)
        else:
            self._put_to_outgoing(message)

    def _notify_elixir_if_connected(self, message: AnyMessage) -> None:
        """Notify Elixir EventBus if bridge is connected.

        This is called AFTER local delivery to also emit to Elixir EventBus.
        Fire-and-forget: never blocks, silently ignores all errors.

        Args:
            message: The message that was just delivered locally.
        """
        try:
            # Lazy import to avoid circular dependencies
            from code_puppy.plugins.elixir_bridge import (
                is_connected,
                notify_elixir_event,
            )

            # Check if bridge is available
            if not is_connected():
                return

            # Extract event type and payload from message
            event_type = message.__class__.__name__
            payload: dict[str, Any] = {"level": "info"}

            # Extract message details based on type
            if hasattr(message, "text"):
                payload["text"] = message.text
            if hasattr(message, "level"):
                payload["level"] = str(message.level)
            if hasattr(message, "category"):
                payload["category"] = str(message.category)

            # Get session_id from message
            session_id = getattr(message, "session_id", None)

            # Fire-and-forget notification to Elixir
            # This returns immediately and handles its own errors silently
            notify_elixir_event(
                event_type=event_type,
                payload=payload,
                run_id=None,  # Could be extended to extract from context
                session_id=session_id,
            )

        except Exception:
            # Silently ignore all errors - this is auxiliary, not critical path
            # Local delivery already succeeded, Elixir notification is bonus
            pass

    def emit(self, message: AnyMessage) -> None:
        """Emit a message to the UI.

        Thread-safe. Can be called from sync or async context.
        If no renderer is active, messages are buffered for later.
        Auto-tags message with current session_id if not already set.
        Also notifies Elixir EventBus if bridge is connected (fire-and-forget).

        Args:
            message: The message to emit.
        """
        # Lock-free fast path: check if renderer is active without acquiring lock.
        # This avoids lock contention in the common case of emit with no subscribers.
        if not self._renderer_event.is_set():
            # No active renderer - buffer the message under lock
            with self._lock:
                if message.session_id is None and self._current_session_id is not None:
                    message.session_id = self._current_session_id
                self._startup_buffer.append(message)
                # deque with maxlen handles eviction automatically (O(1))
            # Also notify Elixir if bridge connected (fire-and-forget, never blocks)
            self._notify_elixir_if_connected(message)
            return

        # Renderer is active - need to acquire lock for session tagging and delivery
        with self._lock:
            self._emit_under_lock(message)

        # Signal the renderer to wake up and check for new messages
        if self._wakeup_callback is not None:
            try:
                self._wakeup_callback()
            except Exception:
                # Don't let wakeup errors break message emission
                pass

        # Also notify Elixir if bridge connected (fire-and-forget, never blocks)
        self._notify_elixir_if_connected(message)

    def emit_text(
        self,
        level: MessageLevel,
        text: str,
        category: MessageCategory = MessageCategory.SYSTEM,
        is_markdown: bool = False,
    ) -> None:
        """Emit a text message with the specified level.

        Args:
            level: Severity level (DEBUG, INFO, WARNING, ERROR, SUCCESS).
            text: Text content. Plain (Rich-markup-escaped) unless is_markdown=True,
                in which case it is rendered as CommonMark markdown.
            category: Message category for routing.
            is_markdown: Whether to render text as markdown (default False).
        """
        message = TextMessage(
            level=level, text=text, category=category, is_markdown=is_markdown
        )

        # Lock-free fast path: check if renderer is active without acquiring lock
        if not self._renderer_event.is_set():
            with self._lock:
                if message.session_id is None and self._current_session_id is not None:
                    message.session_id = self._current_session_id
                self._startup_buffer.append(message)
            return

        # Renderer is active - single lock acquisition for delivery
        with self._lock:
            self._emit_under_lock(message)

        # Signal the renderer to wake up
        if self._wakeup_callback is not None:
            try:
                self._wakeup_callback()
            except Exception:
                pass

    def emit_info(self, text: str, is_markdown: bool = False) -> None:
        """Emit an INFO level text message. Pass is_markdown=True to render as markdown."""
        self.emit_text(MessageLevel.INFO, text, is_markdown=is_markdown)

    def emit_warning(self, text: str, is_markdown: bool = False) -> None:
        """Emit a WARNING level text message. Pass is_markdown=True to render as markdown."""
        self.emit_text(MessageLevel.WARNING, text, is_markdown=is_markdown)

    def emit_error(self, text: str, is_markdown: bool = False) -> None:
        """Emit an ERROR level text message. Pass is_markdown=True to render as markdown."""
        self.emit_text(MessageLevel.ERROR, text, is_markdown=is_markdown)

    def emit_success(self, text: str, is_markdown: bool = False) -> None:
        """Emit a SUCCESS level text message. Pass is_markdown=True to render as markdown."""
        self.emit_text(MessageLevel.SUCCESS, text, is_markdown=is_markdown)

    def emit_debug(self, text: str, is_markdown: bool = False) -> None:
        """Emit a DEBUG level text message. Pass is_markdown=True to render as markdown."""
        self.emit_text(MessageLevel.DEBUG, text, is_markdown=is_markdown)

    def emit_shell_line(self, line: str, stream: str = "stdout") -> None:
        """Emit a shell output line with ANSI preservation.

        Args:
            line: The output line (may contain ANSI codes).
            stream: Which stream this came from ("stdout" or "stderr").
        """
        from .messages import ShellLineMessage

        message = ShellLineMessage(line=line, stream=stream)  # type: ignore[arg-type]

        # Lock-free fast path: check if renderer is active without acquiring lock
        if not self._renderer_event.is_set():
            with self._lock:
                if message.session_id is None and self._current_session_id is not None:
                    message.session_id = self._current_session_id
                self._startup_buffer.append(message)
            return

        # Renderer is active - single lock acquisition for delivery
        with self._lock:
            self._emit_under_lock(message)

        # Signal the renderer to wake up
        if self._wakeup_callback is not None:
            try:
                self._wakeup_callback()
            except Exception:
                pass

    # =========================================================================
    # Internal put helpers (must be called from the event loop thread)
    # =========================================================================

    def _put_to_outgoing(self, message: AnyMessage) -> None:
        """Put a message into the outgoing queue, dropping oldest if full."""
        try:
            self._outgoing.put_nowait(message)
        except asyncio.QueueFull:
            # Drop oldest message and retry
            try:
                self._outgoing.get_nowait()
                self._outgoing.put_nowait(message)
            except asyncio.QueueEmpty:
                pass

    def _put_to_incoming(self, command: AnyCommand) -> None:
        """Put a command into the incoming queue, dropping oldest if full."""
        try:
            self._incoming.put_nowait(command)
        except asyncio.QueueFull:
            # Drop oldest command and retry
            try:
                self._incoming.get_nowait()
                self._incoming.put_nowait(command)
            except asyncio.QueueEmpty:
                pass

    # =========================================================================
    # Session Context (Multi-Agent Tracking)
    # =========================================================================

    def set_session_context(self, session_id: str | None) -> None:
        """Set the current session context for auto-tagging messages.

        When set, all messages emitted via emit() will be automatically tagged
        with this session_id unless they already have one set.

        Args:
            session_id: The session ID to tag messages with, or None to clear.
        """
        with self._lock:
            self._current_session_id = session_id

    def get_session_context(self) -> str | None:
        """Get the current session context.

        Returns:
            The current session_id, or None if not set.
        """
        with self._lock:
            return self._current_session_id

    # =========================================================================
    # User Input Requests (Agent waits for UI response)
    # =========================================================================

    async def request_input(
        self, prompt_text: str, default: str | None = None, input_type: str = "text"
    ) -> str:
        """Request text input from the user.

        Emits a UserInputRequest and blocks until the UI provides a response.

        Args:
            prompt_text: The prompt to display to the user.
            default: Default value if user provides empty input.
            input_type: "text" or "password".

        Returns:
            The user's input string.
        """
        prompt_id = str(uuid4())

        # Create a Future to wait on
        loop = asyncio.get_running_loop()
        # Capture the loop for cross-thread call_soon_threadsafe usage
        if self._event_loop is None:
            self._event_loop = loop
            self._loop_thread_id = threading.current_thread().ident
        future: asyncio.Future[str] = loop.create_future()

        with self._lock:
            self._pending_requests[prompt_id] = future

        # Emit the request
        request = UserInputRequest(
            prompt_id=prompt_id,
            prompt_text=prompt_text,
            default_value=default,
            input_type=input_type,  # type: ignore[arg-type]
        )
        self.emit(request)

        try:
            # Wait for response — timeout prevents permanent hang if UI disconnects
            result = await asyncio.wait_for(
                asyncio.shield(future), timeout=get_bus_request_timeout_seconds()
            )
            return result if result else (default or "")
        except asyncio.TimeoutError:
            return default or ""
        finally:
            # Clean up
            with self._lock:
                self._pending_requests.pop(prompt_id, None)

    async def request_confirmation(
        self,
        title: str,
        description: str,
        options: list[str | None] = None,
        allow_feedback: bool = False,
    ) -> tuple[bool, str | None]:
        """Request confirmation from the user.

        Emits a ConfirmationRequest and blocks until the UI provides a response.

        Args:
            title: Title/headline for the confirmation.
            description: Detailed description of what's being confirmed.
            options: Options to choose from (default: ["Yes", "No"]).
            allow_feedback: Whether to allow free-form feedback.

        Returns:
            Tuple of (confirmed: bool, feedback: str | None).
        """
        prompt_id = str(uuid4())

        loop = asyncio.get_running_loop()
        if self._event_loop is None:
            self._event_loop = loop
            self._loop_thread_id = threading.current_thread().ident
        future: asyncio.Future[tuple[bool, str | None]] = loop.create_future()

        with self._lock:
            self._pending_requests[prompt_id] = future

        request = ConfirmationRequest(
            prompt_id=prompt_id,
            title=title,
            description=description,
            options=options or ["Yes", "No"],
            allow_feedback=allow_feedback,
        )
        self.emit(request)

        try:
            return await asyncio.wait_for(
                asyncio.shield(future), timeout=get_bus_request_timeout_seconds()
            )
        except asyncio.TimeoutError:
            return (False, None)
        finally:
            with self._lock:
                self._pending_requests.pop(prompt_id, None)

    async def request_selection(
        self, prompt_text: str, options: list[str], allow_cancel: bool = True
    ) -> tuple[int, str]:
        """Request the user to select from a list of options.

        Emits a SelectionRequest and blocks until the UI provides a response.

        Args:
            prompt_text: The prompt to display.
            options: List of options to choose from.
            allow_cancel: Whether the user can cancel without selecting.

        Returns:
            Tuple of (selected_index: int, selected_value: str).
            Returns (-1, "") if cancelled.
        """
        prompt_id = str(uuid4())

        loop = asyncio.get_running_loop()
        if self._event_loop is None:
            self._event_loop = loop
            self._loop_thread_id = threading.current_thread().ident
        future: asyncio.Future[tuple[int, str]] = loop.create_future()

        with self._lock:
            self._pending_requests[prompt_id] = future

        request = SelectionRequest(
            prompt_id=prompt_id,
            prompt_text=prompt_text,
            options=options,
            allow_cancel=allow_cancel,
        )
        self.emit(request)

        try:
            return await asyncio.wait_for(
                asyncio.shield(future), timeout=get_bus_request_timeout_seconds()
            )
        except asyncio.TimeoutError:
            return (-1, "")
        finally:
            with self._lock:
                self._pending_requests.pop(prompt_id, None)

    # =========================================================================
    # Incoming Commands (UI → Agent)
    # =========================================================================

    def provide_response(self, command: AnyCommand) -> None:
        """Provide a response to a pending request.

        Called by the UI when the user provides input, confirmation, or selection.
        Matches the response to the waiting request via prompt_id.

        Args:
            command: The response command (UserInputResponse, etc.).
        """
        # Handle user interaction responses
        if isinstance(command, UserInputResponse):
            self._complete_request(command.prompt_id, command.value)
        elif isinstance(command, ConfirmationResponse):
            self._complete_request(
                command.prompt_id, (command.confirmed, command.feedback)
            )
        elif isinstance(command, SelectionResponse):
            self._complete_request(
                command.prompt_id, (command.selected_index, command.selected_value)
            )
        else:
            # For non-response commands (CancelAgentCommand, etc.),
            # put them in the incoming queue for the agent to process.
            # If already on the event loop thread, call directly for
            # immediate delivery. For true cross-thread calls, use
            # call_soon_threadsafe.
            if self._event_loop is not None:
                # Fast path: compare thread IDs instead of calling get_running_loop()
                if threading.current_thread().ident == self._loop_thread_id:
                    # Already on the event loop thread - put directly
                    self._put_to_incoming(command)
                else:
                    try:
                        self._event_loop.call_soon_threadsafe(
                            self._put_to_incoming, command
                        )
                    except RuntimeError:
                        # Loop closed – fall back to direct put
                        self._put_to_incoming(command)
            else:
                self._put_to_incoming(command)

    def _complete_request(self, prompt_id: str, result: object) -> None:
        """Complete a pending request with the given result."""
        with self._lock:
            future = self._pending_requests.get(prompt_id)

        if future is not None and not future.done():
            # Must set result from the event loop thread if we have one.
            # Fast path: if already on the event loop thread, call directly
            # to avoid the overhead of call_soon_threadsafe.
            if self._event_loop is not None:
                # Fast path: compare thread IDs instead of calling get_running_loop()
                if threading.current_thread().ident == self._loop_thread_id:
                    # Already on the event loop thread - call directly
                    self._set_future_result(future, result)
                else:
                    try:
                        self._event_loop.call_soon_threadsafe(
                            self._set_future_result, future, result
                        )
                    except RuntimeError:
                        # Event loop closed - try direct set
                        self._set_future_result(future, result)
            else:
                # No event loop - try direct set
                self._set_future_result(future, result)

    def _set_future_result(self, future: asyncio.Future[Any], result: object) -> None:
        """Set a future's result if not already done."""
        if not future.done():
            future.set_result(result)

    # =========================================================================
    # Queue Access (for renderers/consumers)
    # =========================================================================

    async def get_message(self) -> AnyMessage:
        """Get the next outgoing message (async).

        Called by the renderer to consume messages.
        Blocks until a message is available with zero busy-wait.

        Returns:
            The next message to display.
        """
        # Capture the running loop for cross-thread puts
        if self._event_loop is None:
            self._event_loop = asyncio.get_running_loop()
            self._loop_thread_id = threading.current_thread().ident
        return await self._outgoing.get()

    def get_message_nowait(self) -> AnyMessage | None:
        """Get the next outgoing message without blocking.

        Returns:
            The next message, or None if queue is empty.
        """
        try:
            return self._outgoing.get_nowait()
        except asyncio.QueueEmpty:
            return None

    async def get_command(self) -> AnyCommand:
        """Get the next incoming command (async).

        Called by the agent to consume commands (e.g., CancelAgentCommand).
        Blocks until a command is available with zero busy-wait.

        Returns:
            The next command to process.
        """
        # Capture the running loop for cross-thread puts
        if self._event_loop is None:
            self._event_loop = asyncio.get_running_loop()
            self._loop_thread_id = threading.current_thread().ident
        return await self._incoming.get()

    # =========================================================================
    # Startup Buffering
    # =========================================================================

    def get_buffered_messages(self) -> list[AnyMessage]:
        """Get all messages buffered before renderer attached.

        Uses swap-and-clear pattern for atomic buffer retrieval and reset.

        Returns:
            List of buffered messages.
        """
        with self._lock:
            # Swap-and-clear: atomically swap buffer with new empty one
            old_buffer = self._startup_buffer
            self._startup_buffer = deque(maxlen=self._maxsize)
            return list(old_buffer)

    def mark_renderer_active(self) -> None:
        """Mark that a renderer is now active and consuming messages.

        Call this when a renderer attaches. Messages will no longer be
        buffered and will go directly to the outgoing queue.
        """
        with self._lock:
            self._has_active_renderer = True
        # Lock-free fast path: signal that renderer is ready
        self._renderer_event.set()

    def mark_renderer_inactive(self) -> None:
        """Mark that no renderer is currently active.

        Messages will be buffered until a renderer attaches again.
        """
        with self._lock:
            self._has_active_renderer = False
        # Lock-free fast path: clear renderer ready signal
        self._renderer_event.clear()

    @property
    def has_active_renderer(self) -> bool:
        """Check if a renderer is currently active."""
        with self._lock:
            return self._has_active_renderer

    # =========================================================================
    # Queue Status
    # =========================================================================

    @property
    def outgoing_qsize(self) -> int:
        """Number of messages waiting in the outgoing queue."""
        return self._outgoing.qsize()

    @property
    def incoming_qsize(self) -> int:
        """Number of commands waiting in the incoming queue."""
        return self._incoming.qsize()

    @property
    def pending_requests_count(self) -> int:
        """Number of requests waiting for responses."""
        with self._lock:
            return len(self._pending_requests)


# =============================================================================
# Global Singleton
# =============================================================================

_global_bus: MessageBus | None = None
_bus_lock = threading.Lock()


def get_message_bus() -> MessageBus:
    """Get or create the global MessageBus singleton.

    Thread-safe. Creates the bus on first call.

    Uses double-checked locking pattern to minimize contention:
    - First check (no lock): Fast path for already-initialized bus
    - Second check (with lock): Thread-safe initialization

    Returns:
        The global MessageBus instance.
    """
    global _global_bus

    if _global_bus is None:  # First check (no lock)
        with _bus_lock:
            if _global_bus is None:  # Second check (with lock)
                _global_bus = MessageBus()
    return _global_bus


def reset_message_bus() -> None:
    """Reset the global MessageBus (for testing).

    Warning: This will lose any pending messages/requests!
    """
    global _global_bus

    with _bus_lock:
        _global_bus = None


def reset_global_bus_for_tests() -> None:
    """Reset the global MessageBus singleton for test isolation.

    Properly clears all pending requests and queues before releasing
    the singleton reference. This ensures tests start with a clean state.

    Acquires the bus lock to ensure thread-safe reset.
    """
    global _global_bus

    with _bus_lock:
        if _global_bus is not None:
            # Clear pending requests and their futures
            with _global_bus._lock:
                _global_bus._pending_requests.clear()
                # Drain outgoing queue
                while not _global_bus._outgoing.empty():
                    try:
                        _global_bus._outgoing.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                # Drain incoming queue
                while not _global_bus._incoming.empty():
                    try:
                        _global_bus._incoming.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                # Clear startup buffer
                _global_bus._startup_buffer.clear()
                # Reset renderer state
                _global_bus._has_active_renderer = False
                _global_bus._renderer_event.clear()
                # Clear session context
                _global_bus._current_session_id = None
        _global_bus = None


# =============================================================================
# Convenience Functions
# =============================================================================


def emit(message: AnyMessage) -> None:
    """Emit a message via the global bus."""
    get_message_bus().emit(message)


def emit_info(text: str, is_markdown: bool = False) -> None:
    """Emit an INFO message via the global bus."""
    get_message_bus().emit_info(text, is_markdown=is_markdown)


def emit_warning(text: str, is_markdown: bool = False) -> None:
    """Emit a WARNING message via the global bus."""
    get_message_bus().emit_warning(text, is_markdown=is_markdown)


def emit_error(text: str, is_markdown: bool = False) -> None:
    """Emit an ERROR message via the global bus."""
    get_message_bus().emit_error(text, is_markdown=is_markdown)


def emit_success(text: str, is_markdown: bool = False) -> None:
    """Emit a SUCCESS message via the global bus."""
    get_message_bus().emit_success(text, is_markdown=is_markdown)


def emit_debug(text: str, is_markdown: bool = False) -> None:
    """Emit a DEBUG message via the global bus."""
    get_message_bus().emit_debug(text, is_markdown=is_markdown)


def emit_shell_line(line: str, stream: str = "stdout") -> None:
    """Emit a shell output line with ANSI preservation."""
    get_message_bus().emit_shell_line(line, stream)


def set_session_context(session_id: str | None) -> None:
    """Set the session context on the global bus."""
    get_message_bus().set_session_context(session_id)


def get_session_context() -> str | None:
    """Get the session context from the global bus."""
    return get_message_bus().get_session_context()


# =============================================================================
# Export all public symbols
# =============================================================================

__all__ = [
    # Main class
    "MessageBus",
    # Singleton access
    "get_message_bus",
    "reset_message_bus",
    "reset_global_bus_for_tests",
    # Convenience functions
    "emit",
    "emit_info",
    "emit_warning",
    "emit_error",
    "emit_success",
    "emit_debug",
    "emit_shell_line",
    # Session context
    "set_session_context",
    "get_session_context",
]
