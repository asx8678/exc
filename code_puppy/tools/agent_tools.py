# agent_tools.py
import asyncio
import itertools
import logging
import os
import re
import traceback
from datetime import datetime

# Compile regex patterns once at module level for _sanitize_session_id
_SANITIZE_NON_ALPHANUM_RE = re.compile(r"[^a-z0-9-]+")
_SANITIZE_DASH_RUNS_RE = re.compile(r"-+")

# Hoist ModelMessagesTypeAdapter with try/except guard (fixes lazy import in 3 functions)
try:
    from pydantic_ai.messages import ModelMessagesTypeAdapter
except ImportError:
    ModelMessagesTypeAdapter = None  # type: ignore[misc,assignment]

# Imports for streaming retry logic (transient HTTP error handling)
from functools import partial  # noqa: E402
from pathlib import Path  # noqa: E402

import httpcore  # noqa: E402
import httpx  # noqa: E402

try:
    from dbos import DBOS, SetWorkflowID  # noqa: E402
except ImportError:
    DBOS = None  # type: ignore[assignment,misc]
    SetWorkflowID = None  # type: ignore[assignment,misc]
from pydantic import BaseModel  # noqa: E402

# Import Agent from pydantic_ai to create temporary agents for invocation
from pydantic_ai import Agent, RunContext, UsageLimits  # noqa: E402
from pydantic_ai.exceptions import ModelHTTPError  # noqa: E402
from pydantic_ai.messages import ModelMessage  # noqa: E402

from code_puppy.config import DATA_DIR, get_use_dbos, get_value  # noqa: E402
from code_puppy.config_package import get_puppy_config  # noqa: E402
from code_puppy.dbos_utils import initialize_dbos_if_needed  # noqa: E402
from code_puppy.messaging import (  # noqa: E402
    SubAgentInvocationMessage,
    SubAgentResponseMessage,
    emit_error,
    emit_info,
    emit_success,
    get_message_bus,
    get_session_context,
    set_session_context,
)
from code_puppy.persistence import atomic_write_msgpack, read_msgpack  # noqa: E402
from code_puppy.tools.common import generate_group_id  # noqa: E402
from code_puppy.tools.subagent_context import subagent_context  # noqa: E402

# RunLimiter import with graceful degradation
try:
    from code_puppy.plugins.pack_parallelism.run_limiter import (
        RunConcurrencyLimitError,
        get_run_limiter,
    )

    _RUN_LIMITER_AVAILABLE = True
except ImportError:
    _RUN_LIMITER_AVAILABLE = False
    # Fallback stubs for graceful degradation

    class RunConcurrencyLimitError(Exception):  # type: ignore[no-redef]
        pass

    def get_run_limiter() -> None:  # type: ignore[misc]
        return None


# Set to track active subagent invocation tasks
_active_subagent_tasks: set[asyncio.Task] = set()

# Logger for this module
logger = logging.getLogger(__name__)

# Atomic counter for DBOS workflow IDs - ensures uniqueness even in rapid back-to-back calls
# itertools.count() is thread-safe for next() calls
_dbos_workflow_counter = itertools.count()

# Cache for subagent sessions directory to avoid repeated mkdir/stat calls
_sessions_dir_cache: Path | None = None

# Keys that should NOT propagate from parent agent to sub-agent
# These are either session-specific, parent-private, or would confuse the sub-agent
# Based on deepagents' _EXCLUDED_STATE_KEYS pattern
_EXCLUDED_STATE_KEYS: frozenset[str] = frozenset(
    {
        # Session-specific keys that only make sense for the parent
        "parent_session_id",
        "agent_session_id",
        "session_history",
        # Previous tool results that would clutter the sub-agent's view
        "previous_tool_results",
        "tool_call_history",
        "tool_outputs",
        # Internal state keys
        "_private_state",
        "_internal_metadata",
        # Callback/plugin state that shouldn't leak
        "callback_registry",
        "hook_state",
        # UI/rendering state
        "render_context",
        "console_state",
    }
)


def filter_context_for_subagent(context: dict | None) -> dict:
    """Remove parent-specific state keys before passing context to a sub-agent.

    Based on deepagents' _EXCLUDED_STATE_KEYS pattern. Prevents accidental
    state leakage from parent to sub-agent.

    Args:
        context: The parent agent context dict, or None.

    Returns:
        A new dict with excluded keys removed. Returns empty dict if context is None.

    Example:
        >>> parent_context = {"session_id": "abc", "tool_outputs": [...], "user_prompt": "hi"}
        >>> child_context = filter_context_for_subagent(parent_context)
        >>> "tool_outputs" in child_context
        False
        >>> "user_prompt" in child_context
        True
    """
    if context is None:
        return {}
    return {k: v for k, v in context.items() if k not in _EXCLUDED_STATE_KEYS}


def _generate_dbos_workflow_id(base_id: str) -> str:
    """Generate a unique DBOS workflow ID by appending an atomic counter.

    DBOS requires workflow IDs to be unique across all executions.
    This function ensures uniqueness by combining the base_id with
    an atomically incrementing counter.

    Args:
        base_id: The base identifier (e.g., group_id from generate_group_id)

    Returns:
        A unique workflow ID in format: {base_id}-wf-{counter}
    """
    counter = next(_dbos_workflow_counter)
    return f"{base_id}-wf-{counter}"


# Constants for streaming retry logic
# These match the test constants in tests/agents/test_streaming_retry.py
# NOTE: MAX_STREAMING_RETRIES is set to 1 because the HTTP layer (http_utils.py)
# already handles retries (default 5 retries). Setting this higher would cause
# retry multiplication: streaming_layer(3) × http_layer(5) = 15 total retries!
MAX_STREAMING_RETRIES = 1
STREAMING_RETRY_DELAYS = [1, 2, 4]
_RETRYABLE_STREAMING_EXCEPTIONS = (
    httpx.RemoteProtocolError,
    httpx.ReadTimeout,
    httpcore.RemoteProtocolError,
)


def _is_transient_model_error(error: ModelHTTPError) -> bool:
    """Check if a ModelHTTPError is a transient infrastructure error.

    Some API proxies return HTTP 400 when the upstream connection drops,
    which is actually a transient infrastructure error, not a real client error.
    """
    if error.status_code == 400:
        body_str = str(error.body or "").lower()
        return "connection prematurely closed" in body_str
    return False


async def _run_with_streaming_retry(run_coro_factory, *, model_name: str | None = None):
    """Wrap agent run with retry logic for transient HTTP errors during streaming.

    Catches and retries transient network errors from LLM providers:
    - httpx.RemoteProtocolError (peer closes connection mid-stream)
    - httpx.ReadTimeout (read timeout during streaming)
    - httpcore.RemoteProtocolError (lower-level connection close)

    These errors occur when the LLM provider or an intermediary proxy drops
    the connection during a streamed response. They are always safe to retry
    since no application state has been mutated.

    **Circuit Breaker Integration:**
    Before each retry, checks if the circuit breaker is open for the model.
    If the circuit is open (rate limit active), the retry is aborted to
    prevent wasted API calls against a throttled endpoint.

    **Retry Budget Awareness:**
    This layer only performs 1 retry because the HTTP layer (http_utils.py)
    already handles retries. Multiple retry layers would multiply:
    streaming_layer(3) × http_layer(5) = 15 total retries.

    Args:
        run_coro_factory: A callable that returns a coroutine to run.
        model_name: Optional model name for circuit breaker awareness.

    Returns:
        The result of the coroutine.

    Raises:
        The last retryable exception if all retries are exhausted.
    """
    from code_puppy.adaptive_rate_limiter import is_circuit_open

    last_error = None
    for attempt in range(MAX_STREAMING_RETRIES):
        try:
            return await run_coro_factory()
        except _RETRYABLE_STREAMING_EXCEPTIONS as e:
            last_error = e
            if attempt < MAX_STREAMING_RETRIES - 1:
                # Check circuit breaker before retrying
                if model_name and is_circuit_open(model_name):
                    logger.warning(
                        f"Circuit open for {model_name}, aborting retry after "
                        f"transient error: {e}"
                    )
                    raise last_error
                delay = STREAMING_RETRY_DELAYS[attempt]
                await asyncio.sleep(delay)
        except ModelHTTPError as e:
            if _is_transient_model_error(e):
                last_error = e
                if attempt < MAX_STREAMING_RETRIES - 1:
                    # Check circuit breaker before retrying
                    if model_name and is_circuit_open(model_name):
                        logger.warning(
                            f"Circuit open for {model_name}, aborting retry after "
                            f"transient ModelHTTPError: status={e.status_code}"
                        )
                        raise last_error
                    delay = STREAMING_RETRY_DELAYS[attempt]
                    logger.warning(
                        f"Transient ModelHTTPError (attempt {attempt + 1}/{MAX_STREAMING_RETRIES}): "
                        f"status={e.status_code}, body={e.body}"
                    )
                    await asyncio.sleep(delay)
            else:
                raise
    raise last_error


def _generate_session_hash_suffix() -> str:
    """Generate a unique session ID suffix using uuid4 for collision safety."""
    import uuid

    return uuid.uuid4().hex[:8]


# Regex pattern for kebab-case session IDs
SESSION_ID_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SESSION_ID_MAX_LENGTH = 128


def _sanitize_session_id(raw: str) -> str:
    """Coerce an arbitrary string into a valid kebab-case session_id.

    - Lowercases the string
    - Replaces any character not in [a-z0-9-] with '-'
    - Collapses runs of '-' into a single '-'
    - Strips leading/trailing '-'
    - Truncates to SESSION_ID_MAX_LENGTH
    - Falls back to 'session' if the result would be empty

    This is the defensive counterpart to _validate_session_id: callers at
    public boundaries (like invoke_agent) should sanitize untrusted input
    before passing it to internal helpers that still validate strictly.

    Examples:
        >>> _sanitize_session_id("code_puppy-rjl1.14-worktree")
        'code-puppy-rjl1-14-worktree'
        >>> _sanitize_session_id("MySession")
        'mysession'
        >>> _sanitize_session_id("!!!")
        'session'
    """
    if not isinstance(raw, str):
        raw = str(raw)
    # Lowercase
    s = raw.lower()
    # Replace any char not in [a-z0-9-] with '-' using compiled regex
    s = _SANITIZE_NON_ALPHANUM_RE.sub("-", s)
    # Collapse runs of '-' using compiled regex
    s = _SANITIZE_DASH_RUNS_RE.sub("-", s)
    # Strip leading/trailing '-'
    s = s.strip("-")
    # Truncate
    if len(s) > SESSION_ID_MAX_LENGTH:
        s = s[:SESSION_ID_MAX_LENGTH].rstrip("-")
    # Empty fallback — safe because invoke_agent appends a hash suffix
    # for new sessions, so collisions on the "session" default are avoided.
    if not s:
        s = "session"
    return s


def _validate_session_id(session_id: str) -> None:
    """Validate that a session ID follows kebab-case naming conventions.

    Args:
        session_id: The session identifier to validate

    Raises:
        ValueError: If the session_id is invalid

    Valid format:
        - Lowercase letters (a-z)
        - Numbers (0-9)
        - Hyphens (-) to separate words
        - No uppercase, no underscores, no special characters
        - Length between 1 and 128 characters

    Examples:
        Valid: "my-session", "agent-session-1", "discussion-about-code"
        Invalid: "MySession", "my_session", "my session", "my--session"
    """
    if not session_id:
        raise ValueError("session_id cannot be empty")

    if len(session_id) > SESSION_ID_MAX_LENGTH:
        raise ValueError(
            f"Invalid session_id '{session_id}': must be {SESSION_ID_MAX_LENGTH} characters or less"
        )

    if not SESSION_ID_PATTERN.match(session_id):
        raise ValueError(
            f"Invalid session_id '{session_id}': must be kebab-case "
            "(lowercase letters, numbers, and hyphens only). "
            "Examples: 'my-session', 'agent-session-1', 'discussion-about-code'"
        )


def _get_subagent_sessions_dir() -> Path:
    """Get the directory for storing subagent session data.

    Returns:
        Path to XDG data directory/subagent_sessions/
    """
    global _sessions_dir_cache
    if _sessions_dir_cache is not None:
        return _sessions_dir_cache

    sessions_dir = Path(DATA_DIR) / "subagent_sessions"
    sessions_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    _sessions_dir_cache = sessions_dir
    return sessions_dir


# ----- Sync helpers for session save/load -----


def _save_session_history_sync(
    session_id: str,
    message_history: list[ModelMessage],
    agent_name: str,
    initial_prompt: str | None = None,
) -> None:
    """Sync helper: Save session history to filesystem with folded metadata.

    Args:
        session_id: The session identifier (must be kebab-case)
        message_history: List of messages to save
        agent_name: Name of the agent being invoked
        initial_prompt: The first prompt that started this session (for metadata).
            If None on first save, no initial_prompt is stored.
            If None on subsequent saves, preserves initial_prompt from previous save.

    Raises:
        ValueError: If session_id is not valid kebab-case format
    """
    # Validate session_id format before saving
    _validate_session_id(session_id)

    sessions_dir = _get_subagent_sessions_dir()
    msgpack_path = sessions_dir / f"{session_id}.msgpack"

    # ISSUE 70e FIX: Fold metadata into the msgpack payload; drop separate .txt file.
    # This eliminates TOCTOU race and data-corruption risk from read-modify-write.

    # Check if we need to preserve initial_prompt from previous save
    saved_initial_prompt = initial_prompt
    if initial_prompt is None and msgpack_path.exists():
        try:
            existing_data = read_msgpack(msgpack_path)
            if isinstance(existing_data, dict):
                existing_meta = existing_data.get("metadata", {})
                saved_initial_prompt = existing_meta.get("initial_prompt")
        except Exception:
            pass  # If read fails, proceed without preserving

    payload = {
        "format": "pydantic-ai-json-v2",
        "payload": ModelMessagesTypeAdapter.dump_python(message_history, mode="json")
        if ModelMessagesTypeAdapter
        else [],  # type: ignore[attr]
        "metadata": {
            "session_id": session_id,
            "agent_name": agent_name,
            "initial_prompt": saved_initial_prompt,
            "created_at": datetime.now().isoformat(),
            "message_count": len(message_history),
            "updated_at": datetime.now().isoformat(),
        },
    }
    atomic_write_msgpack(msgpack_path, payload)


def _load_session_history_sync(session_id: str) -> list[ModelMessage]:
    """Sync helper: Load session history from filesystem.

    Args:
        session_id: The session identifier (must be kebab-case)

    Returns:
        List of ModelMessage objects, or empty list if session doesn't exist

    Raises:
        ValueError: If session_id is not valid kebab-case format
    """
    # Validate session_id format before loading
    _validate_session_id(session_id)

    sessions_dir = _get_subagent_sessions_dir()

    # Try msgpack first (new format), fall back to legacy formats
    msgpack_path = sessions_dir / f"{session_id}.msgpack"
    pkl_path = sessions_dir / f"{session_id}.pkl"
    txt_path = sessions_dir / f"{session_id}.txt"

    if msgpack_path.exists():
        try:
            data = read_msgpack(msgpack_path)

            # v2 format with folded metadata
            if isinstance(data, dict) and data.get("format") == "pydantic-ai-json-v2":
                payload = data.get("payload", [])
                return (
                    ModelMessagesTypeAdapter.validate_python(payload)
                    if ModelMessagesTypeAdapter
                    else []
                )
            # v1 format (legacy, no metadata)
            if isinstance(data, dict) and data.get("format") == "pydantic-ai-json":
                payload = data.get("payload", [])
                return (
                    ModelMessagesTypeAdapter.validate_python(payload)
                    if ModelMessagesTypeAdapter
                    else []
                )
            # Oldest format: plain list
            return (
                ModelMessagesTypeAdapter.validate_python(data)
                if ModelMessagesTypeAdapter
                else []
            )
        except Exception:
            pass  # Fall through to other formats or return empty

    # SECURITY FIX j0ha/l1en: Pickle completely removed - RCE vulnerability
    if pkl_path.exists():
        # Legacy pickle format no longer supported due to security (RCE risk)
        # Files must be migrated to msgpack format
        return []

    # Legacy .txt files are ignored (metadata now folded into msgpack)
    # We keep the txt_path reference for cleanup purposes if needed
    _ = txt_path  # Avoid unused variable warning; file may be cleaned up later

    return []


# ----- Async wrappers using asyncio.to_thread -----


async def _save_session_history_async(
    session_id: str,
    message_history: list[ModelMessage],
    agent_name: str,
    initial_prompt: str | None = None,
) -> None:
    """Async wrapper: Save session history using asyncio.to_thread.

    Args:
        session_id: The session identifier (must be kebab-case)
        message_history: List of messages to save
        agent_name: Name of the agent being invoked
        initial_prompt: The first prompt that started this session (for metadata)
    """
    await asyncio.to_thread(
        _save_session_history_sync,
        session_id,
        message_history,
        agent_name,
        initial_prompt,
    )


async def _load_session_history_async(session_id: str) -> list[ModelMessage]:
    """Async wrapper: Load session history using asyncio.to_thread.

    Args:
        session_id: The session identifier (must be kebab-case)

    Returns:
        List of ModelMessage objects, or empty list if session doesn't exist
    """
    return await asyncio.to_thread(_load_session_history_sync, session_id)


class AgentInfo(BaseModel):
    """Information about an available agent."""

    name: str
    display_name: str
    description: str


class ListAgentsOutput(BaseModel):
    """Output for the list_agents tool."""

    agents: list[AgentInfo]
    error: str | None = None


class AgentInvokeOutput(BaseModel):
    """Output for the invoke_agent tool."""

    response: str | None
    agent_name: str
    session_id: str | None = None
    error: str | None = None


def register_list_agents(agent):
    """Register the list_agents tool with the provided agent.

    Args:
        agent: The agent to register the tool with
    """

    @agent.tool
    async def list_agents(context: RunContext) -> ListAgentsOutput:
        """List all available sub-agents that can be invoked."""
        # Generate a group ID for this tool execution
        group_id = generate_group_id("list_agents")

        from rich.text import Text

        from code_puppy.config import get_banner_color

        list_agents_color = get_banner_color("list_agents")

        try:
            # Try Elixir bridge first (code_puppy-mmk.4)
            agents = None
            try:
                from code_puppy.plugins.elixir_bridge import (
                    call_elixir_agent_tools,
                    is_connected,
                )

                if is_connected():
                    try:
                        # Use _run_async_safe to avoid unsafe asyncio.run()
                        # when an event loop is already running (e.g. inside
                        # a pydantic-ai agent tool context).
                        result = await call_elixir_agent_tools(
                            "agent_tools.list",
                            {},
                            timeout=2.0,
                        )
                        if result.get("status") != "timeout" and "agents" in result:
                            agents = [
                                AgentInfo(
                                    name=a["name"],
                                    display_name=a["display_name"],
                                    description=a["description"],
                                )
                                for a in result["agents"]
                            ]
                    except Exception as exc:
                        logger.debug(
                            "list_agents: Elixir bridge error: %s, falling back",
                            exc,
                        )
            except ImportError:
                logger.debug(
                    "list_agents: elixir_bridge not importable, using local fallback"
                )
                pass

            if agents is None:
                # Local fallback
                from code_puppy.agents import (
                    get_agent_descriptions,
                    get_available_agents,
                )

                agents_dict = get_available_agents()
                descriptions_dict = get_agent_descriptions()

                agents = [
                    AgentInfo(
                        name=name,
                        display_name=display_name,
                        description=descriptions_dict.get(
                            name, "No description available"
                        ),
                    )
                    for name, display_name in agents_dict.items()
                ]

            # Quiet output - banner and count on same line
            agent_count = len(agents)
            emit_info(
                Text.from_markup(
                    f"[bold white on {list_agents_color}] LIST AGENTS [/bold white on {list_agents_color}] "
                    f"[dim]Found {agent_count} agent(s).[/dim]"
                ),
                message_group=group_id,
            )

            return ListAgentsOutput(agents=agents)

        except Exception as e:
            error_msg = f"Error listing agents: {str(e)}"
            emit_error(error_msg, message_group=group_id)
            return ListAgentsOutput(agents=[], error=error_msg)

    return list_agents


def register_invoke_agent(agent):
    """Register the invoke_agent tool with the provided agent.

    Args:
        agent: The agent to register the tool with
    """

    @agent.tool
    async def invoke_agent(
        context: RunContext, agent_name: str, prompt: str, session_id: str | None = None
    ) -> AgentInvokeOutput:
        """Invoke a specific sub-agent with a given prompt.

        Returns:
            AgentInvokeOutput: Contains response, agent_name, session_id, and error fields.
        """
        from code_puppy.agents.agent_manager import load_agent

        # Defensive sanitization: user/LLM-provided session IDs may contain
        # underscores, dots, or other characters that the strict validator
        # rejects. Coerce to valid kebab-case and log a warning so we can
        # track callers that need to be educated.
        if session_id is not None:
            sanitized_session_id = _sanitize_session_id(session_id)
            if sanitized_session_id != session_id:
                logging.getLogger(__name__).warning(
                    "invoke_agent: session_id %r was not valid kebab-case; "
                    "sanitized to %r. Update the caller to pass clean IDs.",
                    session_id,
                    sanitized_session_id,
                )
                session_id = sanitized_session_id

        # Generate a group ID for this tool execution
        group_id = generate_group_id("invoke_agent", agent_name)

        # Check if this is an existing session or a new one
        # For user-provided session_id, check if it exists
        # For None, we'll generate a new one below
        if session_id is not None:
            message_history = await _load_session_history_async(session_id)
            is_new_session = len(message_history) == 0
        else:
            message_history = []
            is_new_session = True

        # Generate or finalize session_id
        if session_id is None:
            # Auto-generate a session ID with hash suffix for uniqueness
            # Example: "qa-expert-session-a3f2b1"
            hash_suffix = _generate_session_hash_suffix()
            # Sanitize agent_name: replace underscores with hyphens for kebab-case compliance
            sanitized_agent_name = agent_name.replace("_", "-").lower()
            session_id = f"{sanitized_agent_name}-session-{hash_suffix}"
        elif is_new_session:
            # User provided a base name for a NEW session - append hash suffix
            # Example: "review-auth" -> "review-auth-a3f2b1"
            hash_suffix = _generate_session_hash_suffix()
            session_id = f"{session_id}-{hash_suffix}"
        # else: continuing existing session, use session_id as-is

        # ── Elixir bridge fast-path (code_puppy-mmk.4) ────────────────────
        # Attempt agent_tools.invoke via Elixir when connected and NOT
        # inside an Elixir-managed worker (which would recurse).
        _skip_elixir = os.environ.get("PUP_SKIP_ELIXIR_AGENT_TOOLS", "").strip() in (
            "1",
            "true",
            "yes",
        )
        if not _skip_elixir:
            try:
                from code_puppy.plugins.elixir_bridge import (
                    call_elixir_agent_tools,
                    is_connected,
                )

                if is_connected():
                    try:
                        bridge_result = await call_elixir_agent_tools(
                            "agent_tools.invoke",
                            {
                                "agent_name": agent_name,
                                "prompt": prompt,
                                "session_id": session_id,
                            },
                            timeout=30.0,
                        )
                        if bridge_result.get(
                            "status"
                        ) != "timeout" and not bridge_result.get("error"):
                            bridge_resp = bridge_result.get("response")
                            if bridge_resp is not None:
                                logger.debug(
                                    "invoke_agent: Elixir bridge responded for %s",
                                    agent_name,
                                )
                                # Emit invocation + response events for parity
                                bus = get_message_bus()
                                bus.emit(
                                    SubAgentInvocationMessage(
                                        agent_name=agent_name,
                                        session_id=session_id,
                                        prompt=prompt,
                                        is_new_session=is_new_session,
                                        message_count=len(message_history),
                                    )
                                )
                                bus.emit(
                                    SubAgentResponseMessage(
                                        agent_name=agent_name,
                                        session_id=session_id,
                                        response=bridge_resp,
                                        message_count=0,
                                        was_streamed=False,
                                        streamed_line_count=0,
                                    )
                                )
                                emit_success(
                                    f"✓ {agent_name} completed via Elixir bridge",
                                    message_group=group_id,
                                )
                                return AgentInvokeOutput(
                                    response=bridge_resp,
                                    agent_name=agent_name,
                                    session_id=session_id,
                                )
                        logger.debug(
                            "invoke_agent: Elixir bridge timeout/error for %s, falling back to local",
                            agent_name,
                        )
                    except Exception as exc:
                        logger.debug(
                            "invoke_agent: Elixir bridge exception for %s: %s, falling back",
                            agent_name,
                            exc,
                        )
            except ImportError:
                logger.debug(
                    "invoke_agent: elixir_bridge not importable, using local path"
                )
        else:
            logger.debug(
                "invoke_agent: PUP_SKIP_ELIXIR_AGENT_TOOLS=1, skipping Elixir for %s",
                agent_name,
            )
        # ── End Elixir bridge fast-path ───────────────────────────────────

        # Lazy imports to avoid circular dependency
        from code_puppy.agents.subagent_stream_handler import subagent_stream_handler

        # Emit structured invocation message via MessageBus
        bus = get_message_bus()
        bus.emit(
            SubAgentInvocationMessage(
                agent_name=agent_name,
                session_id=session_id,
                prompt=prompt,
                is_new_session=is_new_session,
                message_count=len(message_history),
            )
        )

        # Save current session context and set the new one for this sub-agent
        previous_session_id = get_session_context()
        set_session_context(session_id)

        # Browser session context removed (DROP-V1 — djs.2)

        try:
            # Lazy import to break circular dependency with messaging module
            from code_puppy.model_factory import ModelFactory, make_model_settings

            # Load the specified agent config
            agent_config = load_agent(agent_name)

            # Get the current model for creating a temporary agent
            model_name = agent_config.get_model_name()
            models_config = ModelFactory.load_config()

            # Only proceed if we have a valid model configuration
            if model_name not in models_config:
                raise ValueError(f"Model '{model_name}' not found in configuration")

            model = ModelFactory.get_model(model_name, models_config)

            # Guard against None model (e.g. missing API keys) — get_model
            # should raise ValueError in this case, but defend in depth since
            # DBOSAgent will produce a confusing error if model is None.
            if model is None:
                raise ValueError(
                    f"Failed to initialize model '{model_name}' for agent "
                    f"'{agent_name}'. Check that required API keys are set."
                )

            # Create a temporary agent instance to avoid interfering with current agent state
            instructions = agent_config.get_full_system_prompt()

            # Add AGENTS.md content to subagents
            puppy_rules = agent_config.load_puppy_rules()
            if puppy_rules:
                instructions += f"\n\n{puppy_rules}"
            from code_puppy.model_utils import prepare_prompt_for_model

            # Handle claude-code models: swap instructions, and prepend system prompt only on first message
            prepared = prepare_prompt_for_model(
                model_name,
                instructions,
                prompt,
                prepend_system_to_user=is_new_session,  # Only prepend on first message
            )
            instructions = prepared.instructions
            prompt = prepared.user_prompt

            import uuid as _uuid

            subagent_name = f"temp-invoke-agent-{session_id}-{_uuid.uuid4().hex[:8]}"
            model_settings = make_model_settings(model_name)

            # Get MCP servers for sub-agents (same as main agent)
            from code_puppy.mcp_ import get_mcp_manager

            mcp_servers = []
            mcp_disabled = get_value("disable_mcp_servers")
            if not (
                mcp_disabled and str(mcp_disabled).lower() in ("1", "true", "yes", "on")
            ):
                manager = get_mcp_manager()
                mcp_servers = manager.get_servers_for_agent()

            if get_use_dbos():
                from pydantic_ai.durable_exec.dbos import DBOSAgent

                # Ensure DBOS is initialized before using DBOS-dependent features
                if not initialize_dbos_if_needed():
                    from code_puppy.messaging import emit_warning

                    emit_warning(
                        "DBOS auto-reinitialization failed. Workflow durability may be unavailable."
                    )

                # For DBOS, create agent without MCP servers (to avoid serialization issues)
                # and add them at runtime
                temp_agent = Agent(
                    model=model,
                    instructions=instructions,
                    output_type=str,
                    retries=3,
                    toolsets=[],  # MCP servers added separately for DBOS
                    history_processors=[agent_config.message_history_accumulator],
                    model_settings=model_settings,
                )

                # Register the tools that the agent needs
                from code_puppy.tools import register_tools_for_agent

                agent_tools = agent_config.get_available_tools()
                register_tools_for_agent(temp_agent, agent_tools, model_name=model_name)

                # Wrap with DBOS - no streaming for sub-agents
                dbos_agent = DBOSAgent(temp_agent, name=subagent_name)
                temp_agent = dbos_agent

                # Store MCP servers to add at runtime
                subagent_mcp_servers = mcp_servers
            else:
                # Non-DBOS path - include MCP servers directly in the agent
                temp_agent = Agent(
                    model=model,
                    instructions=instructions,
                    output_type=str,
                    retries=3,
                    toolsets=mcp_servers,
                    history_processors=[agent_config.message_history_accumulator],
                    model_settings=model_settings,
                )

                # Register the tools that the agent needs
                from code_puppy.tools import register_tools_for_agent

                agent_tools = agent_config.get_available_tools()
                register_tools_for_agent(temp_agent, agent_tools, model_name=model_name)

                subagent_mcp_servers = None

            # Run the temporary agent with the provided prompt as an asyncio task
            # Pass the message_history from the session to continue the conversation
            workflow_id = None  # Track for potential cancellation

            # Always use subagent_stream_handler to silence output and update console manager
            # This ensures all sub-agent output goes through the aggregated dashboard
            stream_handler = partial(subagent_stream_handler, session_id=session_id)

            # RunLimiter: centralized concurrency control for agent invocations
            run_limiter = get_run_limiter() if _RUN_LIMITER_AVAILABLE else None

            async def _run_with_limiter():
                """Inner async function to enable limiter wrapping."""
                # Notify if queued
                if run_limiter is not None:
                    waiters = run_limiter.waiters_count
                    if waiters > 0:
                        emit_info(
                            f"[RunLimiter] Queued behind {waiters} other run(s); waiting...",
                            message_group=group_id,
                        )

                # Acquire slot (may wait if at limit)
                if run_limiter is not None:
                    await run_limiter.acquire_async()

                try:
                    # Wrap the agent run in subagent context for tracking
                    with subagent_context(agent_name):
                        if get_use_dbos():
                            # Generate a unique workflow ID for DBOS - ensures no collisions in back-to-back calls
                            nonlocal workflow_id
                            workflow_id = _generate_dbos_workflow_id(group_id)

                            # Add MCP servers to the DBOS agent's toolsets
                            # (temp_agent is discarded after this invocation, so no need to restore)
                            if subagent_mcp_servers:
                                temp_agent._toolsets = (
                                    temp_agent._toolsets + subagent_mcp_servers
                                )

                            with SetWorkflowID(workflow_id):
                                task = asyncio.create_task(
                                    _run_with_streaming_retry(
                                        lambda: temp_agent.run(
                                            prompt,
                                            message_history=message_history,
                                            usage_limits=UsageLimits(
                                                request_limit=get_puppy_config().message_limit
                                            ),
                                            event_stream_handler=stream_handler,
                                        ),
                                        model_name=model_name,
                                    )
                                )
                                _active_subagent_tasks.add(task)
                        else:
                            task = asyncio.create_task(
                                _run_with_streaming_retry(
                                    lambda: temp_agent.run(
                                        prompt,
                                        message_history=message_history,
                                        usage_limits=UsageLimits(
                                            request_limit=get_puppy_config().message_limit
                                        ),
                                        event_stream_handler=stream_handler,
                                    ),
                                    model_name=model_name,
                                )
                            )
                            _active_subagent_tasks.add(task)

                        try:
                            result = await task
                        finally:
                            _active_subagent_tasks.discard(task)
                            if task.cancelled():
                                if get_use_dbos() and workflow_id:
                                    await DBOS.cancel_workflow_async(workflow_id)

                    # Extract the response from the result
                    response = result.output

                    # Update the session history with the new messages from this interaction
                    # The result contains all_messages which includes the full conversation
                    updated_history = result.all_messages()

                    # Save to filesystem async (include initial prompt only for new sessions)
                    await _save_session_history_async(
                        session_id=session_id,
                        message_history=updated_history,
                        agent_name=agent_name,
                        initial_prompt=prompt if is_new_session else None,
                    )

                    # Emit structured response message via MessageBus
                    from code_puppy.agents.event_stream_handler import get_stream_state

                    did_stream, line_count = get_stream_state()
                    bus.emit(
                        SubAgentResponseMessage(
                            agent_name=agent_name,
                            session_id=session_id,
                            response=response,
                            message_count=len(updated_history),
                            was_streamed=did_stream,
                            streamed_line_count=line_count,
                        )
                    )

                    # Emit clean completion summary
                    emit_success(
                        f"✓ {agent_name} completed successfully", message_group=group_id
                    )

                    return AgentInvokeOutput(
                        response=response, agent_name=agent_name, session_id=session_id
                    )
                finally:
                    # Release the limiter slot
                    if run_limiter is not None:
                        run_limiter.release()

            # Execute with or without limiter
            if run_limiter is not None:
                return await _run_with_limiter()
            else:
                return (
                    await _run_with_limiter()
                )  # Limiter is None inside, works as no-op

        except Exception as e:
            # Emit clean failure summary
            emit_error(f"✗ {agent_name} failed: {str(e)}", message_group=group_id)

            # Full traceback for debugging
            error_msg = f"Error invoking agent '{agent_name}': {traceback.format_exc()}"
            emit_error(error_msg, message_group=group_id)

            return AgentInvokeOutput(
                response=None,
                agent_name=agent_name,
                session_id=session_id,
                error=error_msg,
            )

        finally:
            # Restore the previous session context
            set_session_context(previous_session_id)
            # Browser session context removed (DROP-V1 — djs.2)

    return invoke_agent


async def invoke_agent_headless(
    agent_name: str,
    prompt: str,
    session_id: str | None = None,
) -> str:
    """Invoke a sub-agent without RunContext — for plugin use.

    Simplified version of the invoke_agent tool closure that can be
    imported at module level. Used by plugins like supervisor_review
    that need to invoke agents outside of a pydantic-ai tool context.

    Does NOT handle: streaming dashboards, DBOS workflows, browser/terminal
    session isolation, or session persistence. For the full-featured version,
    use the invoke_agent tool registered via register_invoke_agent().

    Args:
        agent_name: Name of the agent to invoke (e.g. "code-puppy").
        prompt: The prompt to send to the agent.
        session_id: Optional session ID for the invocation. Auto-generated
            if None. Used for logging/tracking only (no persistence).

    Returns:
        The agent's text response.

    Raises:
        RuntimeError: If agent loading or model initialization fails.
    """
    # Prevent recursive delegation: when Python is running inside an
    # Elixir-managed worker (bridge_controller), we must NOT delegate
    # back to Elixir — that would create an infinite loop.
    # PUP_SKIP_ELIXIR_AGENT_TOOLS is set by bridge_controller before
    # calling this function from within an Elixir-managed context.
    _skip_elixir = os.environ.get("PUP_SKIP_ELIXIR_AGENT_TOOLS", "").strip() in (
        "1",
        "true",
        "yes",
    )

    # Try Elixir bridge first (code_puppy-mmk.4) — only when NOT in
    # an Elixir-managed worker context.
    if not _skip_elixir:
        try:
            from code_puppy.plugins.elixir_bridge import (
                call_elixir_agent_tools,
                is_connected,
            )

            if is_connected():
                try:
                    result = await call_elixir_agent_tools(
                        "agent_tools.invoke_headless",
                        {
                            "agent_name": agent_name,
                            "prompt": prompt,
                            "session_id": session_id,
                        },
                        timeout=30.0,
                    )
                    if result.get("status") != "timeout" and "response" in result:
                        logger.debug(
                            "invoke_agent_headless: got response from Elixir bridge for %s",
                            agent_name,
                        )
                        return result["response"]
                    logger.debug(
                        "invoke_agent_headless: Elixir bridge returned timeout/no-response for %s, falling back",
                        agent_name,
                    )
                except Exception as exc:
                    logger.debug(
                        "invoke_agent_headless: Elixir bridge error for %s: %s, falling back",
                        agent_name,
                        exc,
                    )
        except ImportError:
            logger.debug(
                "invoke_agent_headless: elixir_bridge not importable, using local fallback"
            )
    else:
        logger.debug(
            "invoke_agent_headless: PUP_SKIP_ELIXIR_AGENT_TOOLS=1, skipping Elixir delegation for %s",
            agent_name,
        )

    # Local fallback
    from code_puppy.agents.agent_manager import load_agent
    from code_puppy.model_factory import ModelFactory, make_model_settings
    from code_puppy.model_utils import prepare_prompt_for_model
    from code_puppy.tools import register_tools_for_agent

    # Load agent config
    agent_config = load_agent(agent_name)
    model_name = agent_config.get_model_name()
    models_config = ModelFactory.load_config()

    if model_name not in models_config:
        raise RuntimeError(f"Model '{model_name}' not found in configuration")

    model = ModelFactory.get_model(model_name, models_config)
    if model is None:
        raise RuntimeError(
            f"Failed to initialize model '{model_name}' for agent "
            f"'{agent_name}'. Check that required API keys are set."
        )

    # Build instructions
    instructions = agent_config.get_full_system_prompt()
    puppy_rules = agent_config.load_puppy_rules()
    if puppy_rules:
        instructions += f"\n\n{puppy_rules}"

    # Handle model-specific prompt preparation
    prepared = prepare_prompt_for_model(
        model_name,
        instructions,
        prompt,
        prepend_system_to_user=True,
    )
    instructions = prepared.instructions
    prompt = prepared.user_prompt

    # Create temp agent
    model_settings = make_model_settings(model_name)
    temp_agent = Agent(
        model=model,
        instructions=instructions,
        output_type=str,
        retries=3,
        model_settings=model_settings,
    )

    # Register tools
    agent_tools = agent_config.get_available_tools()
    register_tools_for_agent(temp_agent, agent_tools, model_name=model_name)

    # RunLimiter: respect concurrency limits if available
    run_limiter = get_run_limiter() if _RUN_LIMITER_AVAILABLE else None
    if run_limiter is not None:
        await run_limiter.acquire_async()

    try:
        result = await temp_agent.run(
            prompt,
            usage_limits=UsageLimits(request_limit=get_puppy_config().message_limit),
        )
        return str(result.output)
    finally:
        if run_limiter is not None:
            run_limiter.release()
