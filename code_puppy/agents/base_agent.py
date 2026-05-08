"""Base agent configuration class for defining agent properties."""

import asyncio
import contextlib
import dataclasses
import hashlib
import json
import logging
import signal
import threading
import time
import uuid
from abc import ABC, abstractmethod
from collections.abc import Callable
from typing import Any, Sequence

import mcp
import pydantic

from code_puppy.token_ledger import TokenAttempt
from code_puppy.utils.overflow_detect import is_context_overflow
from code_puppy.utils.thread_safe_cache import thread_safe_lru_cache

try:
    from dbos import DBOS, SetWorkflowID
except ImportError:
    DBOS = None  # type: ignore[assignment,misc]
    SetWorkflowID = None  # type: ignore[assignment,misc]
from pydantic_ai import Agent as PydanticAgent
from pydantic_ai import (
    BinaryContent,
    DocumentUrl,
    ImageUrl,
    RunContext,
    UsageLimitExceeded,
    UsageLimits,
)
from pydantic_ai.exceptions import UnexpectedModelBehavior

try:
    from pydantic_ai.durable_exec.dbos import DBOSAgent
except ImportError:
    DBOSAgent = None  # type: ignore[assignment,misc]

from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelResponse,
    TextPart,
    ThinkingPart,
    ToolCallPart,
    ToolCallPartDelta,
    ToolReturn,
    ToolReturnPart,
)
from rich.text import Text

from code_puppy.agents.agent_prompt_mixin import AgentPromptMixin
from code_puppy.agents.agent_state import AgentRuntimeState
from code_puppy.agents.event_stream_handler import event_stream_handler
from code_puppy.callbacks import (
    count_callbacks,
    on_agent_exception,
    on_agent_run_end,
    on_agent_run_start,
    on_message_history_processor_end,
    on_message_history_processor_start,
)

# Compaction module for enhanced summarization (deepagents port)
from code_puppy.compaction import (
    compute_summarization_thresholds,
    offload_evicted_messages,
    pretruncate_messages,
)
from code_puppy.compaction.shadow_mode import shadow_prune_and_filter

# Consolidated relative imports
from code_puppy.config import (
    get_agent_pinned_model,
    get_compaction_strategy,
    get_global_model_name,
    get_use_dbos,
    get_value,
)
from code_puppy.config_package import get_puppy_config
from code_puppy.error_logging import log_error
from code_puppy.keymap import cancel_agent_uses_signal, get_cancel_agent_char_code
from code_puppy.mcp_ import get_mcp_manager
from code_puppy.messaging import emit_error, emit_info, emit_warning
from code_puppy.messaging.spinner import SpinnerBase, update_spinner_context
from code_puppy.model_factory import (
    ModelFactory,
    make_model_settings,
    resolve_max_output_tokens,
)
from code_puppy.summarization_agent import SummarizationError, run_summarization_sync
from code_puppy.token_utils import estimate_token_count as _estimate_token_count
from code_puppy.tools.agent_tools import _active_subagent_tasks
from code_puppy.tools.command_runner import is_awaiting_user_input
from code_puppy.utils.binary_token_estimation import (
    estimate_binary_content_tokens as _estimate_binary_content_tokens,
)

_reload_count = 0


logger = logging.getLogger(__name__)


# LRU cache for JSON schema serialization to avoid redundant work
# in estimate_context_overhead_tokens(). Schemas are static, so caching
# provides significant performance benefits for repeated token estimations.
@thread_safe_lru_cache(maxsize=128)
def _serialize_schema_to_json(schema_json: str) -> str:
    """Return canonical JSON for a schema.

    The input is already a canonical JSON string; caching avoids
    redundant re-serialization when the same schema appears multiple times.
    This approach handles nested dicts correctly (unlike tuple-based keys).

    Args:
        schema_json: Canonical JSON string representation of the schema.

    Returns:
        The same JSON string (cached for performance).
    """
    return schema_json


class BaseAgent(ABC, AgentPromptMixin):
    """Base class for all agent configurations.

    This class separates immutable configuration (name, description, system_prompt)
    from mutable runtime state (message history, caches, etc.) using the
    AgentRuntimeState container.

    The mutable state is stored in `_state` attribute, while config is provided
    through abstract properties that subclasses must implement.
    """

    __slots__ = (
        "id",
        "_state",
    )

    def __init__(self):
        self.id = str(uuid.uuid7())  # time-sortable for chronological ordering
        # Mutable runtime state container - separates state from immutable config
        self._state = AgentRuntimeState()

    # Backward-compatible properties that delegate to _state for migration support
    @property
    def _puppy_rules(self) -> str | None:
        """Backward-compatible property delegating to _state.puppy_rules."""
        return self._state.puppy_rules

    @_puppy_rules.setter
    def _puppy_rules(self, value: str | None) -> None:
        """Backward-compatible setter delegating to _state.puppy_rules."""
        self._state.puppy_rules = value

    @property
    def _message_history(self) -> list[Any]:
        """Backward-compatible property delegating to _state.message_history."""
        return self._state.message_history

    @_message_history.setter
    def _message_history(self, value: list[Any]) -> None:
        """Backward-compatible setter delegating to _state.message_history."""
        self._state.message_history = value

    @property
    def _model_name_cache(self) -> str | None:
        """Backward-compatible property delegating to _state.model_name_cache."""
        return self._state.model_name_cache

    @_model_name_cache.setter
    def _model_name_cache(self, value: str | None) -> None:
        """Backward-compatible setter delegating to _state.model_name_cache."""
        self._state.model_name_cache = value

    @property
    def _cached_context_overhead(self) -> int | None:
        """Backward-compatible property delegating to _state.cached_context_overhead."""
        return self._state.cached_context_overhead

    @_cached_context_overhead.setter
    def _cached_context_overhead(self, value: int | None) -> None:
        """Backward-compatible setter delegating to _state.cached_context_overhead."""
        self._state.cached_context_overhead = value

    @property
    def _delayed_compaction_requested(self) -> bool:
        """Backward-compatible property delegating to _state.delayed_compaction_requested."""
        return self._state.delayed_compaction_requested

    @_delayed_compaction_requested.setter
    def _delayed_compaction_requested(self, value: bool) -> None:
        """Backward-compatible setter delegating to _state.delayed_compaction_requested."""
        self._state.delayed_compaction_requested = value

    @property
    def _tool_ids_cache(self) -> Any:
        """Backward-compatible property delegating to _state.tool_ids_cache."""
        return self._state.tool_ids_cache

    @_tool_ids_cache.setter
    def _tool_ids_cache(self, value: Any) -> None:
        """Backward-compatible setter delegating to _state.tool_ids_cache."""
        self._state.tool_ids_cache = value

    @property
    def _mcp_tool_definitions_cache(self) -> list[dict[str, Any]]:
        """Backward-compatible property delegating to _state.mcp_tool_definitions_cache."""
        return self._state.mcp_tool_definitions_cache

    @_mcp_tool_definitions_cache.setter
    def _mcp_tool_definitions_cache(self, value: list[dict[str, Any]]) -> None:
        """Backward-compatible setter delegating to _state.mcp_tool_definitions_cache."""
        self._state.mcp_tool_definitions_cache = value

    @property
    def _mcp_servers(self) -> list[Any]:
        """Backward-compatible property delegating to _state.mcp_servers."""
        return self._state.mcp_servers

    @_mcp_servers.setter
    def _mcp_servers(self, value: list[Any]) -> None:
        """Backward-compatible setter delegating to _state.mcp_servers."""
        self._state.mcp_servers = value

    @property
    def _code_generation_agent(self) -> Any:
        """Backward-compatible property delegating to _state.code_generation_agent."""
        return self._state.code_generation_agent

    @_code_generation_agent.setter
    def _code_generation_agent(self, value: Any) -> None:
        """Backward-compatible setter delegating to _state.code_generation_agent."""
        self._state.code_generation_agent = value

    def _invalidate_token_caches(self) -> None:
        """Invalidate all token-related caches.

        Call this when prompt/tool topology changes:
        - MCP tools added/removed
        - Working directory changes
        - Project rules reload
        """
        self._state.invalidate_all_token_caches()

    @property
    def _cached_context_overhead(self) -> int | None:
        """Backward-compatible property delegating to _state.cached_context_overhead."""
        return self._state.cached_context_overhead

    @_cached_context_overhead.setter
    def _cached_context_overhead(self, value: int | None) -> None:
        """Backward-compatible setter delegating to _state.cached_context_overhead."""
        self._state.cached_context_overhead = value

    @property
    @abstractmethod
    def name(self) -> str:
        """Unique identifier for the agent."""
        pass

    @property
    @abstractmethod
    def display_name(self) -> str:
        """Human-readable name for the agent."""
        pass

    @property
    @abstractmethod
    def description(self) -> str:
        """Brief description of what this agent does."""
        pass

    @abstractmethod
    def get_system_prompt(self) -> str:
        """Get the system prompt for this agent."""
        pass

    @abstractmethod
    def get_available_tools(self) -> list[str]:
        """Get list of tool names that this agent should have access to.

        Returns:
            List of tool names to register for this agent.
        """
        pass

    def get_tools_config(self) -> dict[str, Any] | None:
        """Get tool configuration for this agent.

        Returns:
            Dict with tool configuration, or None to use default tools.
        """
        return None

    def get_user_prompt(self) -> str | None:
        """Get custom user prompt for this agent.

        Returns:
            Custom prompt string, or None to use default.
        """
        return None

    # Message history management methods
    def get_message_history(self) -> list[Any]:
        """Get the message history for this agent.

        Returns:
            List of messages in this agent's conversation history.
        """
        return self._state.message_history

    def set_message_history(self, history: list[Any]) -> None:
        """Set the message history for this agent.

        Args:
            history: List of messages to set as the conversation history.
        """
        self._state.message_history = history
        # Rebuild hash set when history is replaced wholesale
        self._state.message_history_hashes = set(self.hash_message(m) for m in history)

    def clear_message_history(self) -> None:
        """Clear the message history for this agent."""
        self._state.clear_history()

    def append_to_message_history(self, message: Any) -> None:
        """Append a message to this agent's history.

        Args:
            message: Message to append to the conversation history.
        """
        self._state.append_message(message, self.hash_message(message))

    def extend_message_history(self, history: list[Any]) -> None:
        """Extend this agent's message history with multiple messages.

        Args:
            history: List of messages to append to the conversation history.
        """
        hashes = [self.hash_message(m) for m in history]
        self._state.extend_history(history, hashes)

    def get_compacted_message_hashes(self) -> set[str]:
        """Get the set of compacted message hashes for this agent.

        Returns:
            Set of hashes for messages that have been compacted/summarized.
        """
        return self._state.compacted_message_hashes

    def add_compacted_message_hash(self, message_hash: str) -> None:
        """Add a message hash to the set of compacted message hashes.

        Args:
            message_hash: Hash of a message that has been compacted/summarized.
        """
        self._state.compacted_message_hashes.add(message_hash)

    def restore_compacted_hashes(self, hashes: list) -> None:
        """Restore compacted message hashes from a persisted session.

        Args:
            hashes: List of message hashes (int or str) to restore into the
                    internal compacted-hashes set.
        """
        self._state.compacted_message_hashes = set(hashes)

    def get_model_name(self) -> str | None:
        """Get pinned model name for this agent, if specified.

        Uses per-instance caching to avoid repeated config lookups.
        Only caches when a pinned model is set (stable); always looks up
        global model to avoid staleness when global model changes.

        Returns:
            Model name to use for this agent, or global default if none pinned.
        """
        # Only use cache if we have a pinned model (stable)
        if self._state.model_name_cache is not None:
            return self._state.model_name_cache

        pinned = get_agent_pinned_model(self.name)
        if pinned == "" or pinned is None:
            return get_global_model_name()

        # Cache the pinned model and return it
        self._state.model_name_cache = pinned
        return self._state.model_name_cache

    def ensure_history_ends_with_request(
        self, messages: list[ModelMessage]
    ) -> list[ModelMessage]:
        """Ensure message history ends with a ModelRequest.

        pydantic_ai requires that processed message history ends with a ModelRequest.
        This can fail when swapping models mid-conversation if the history ends with
        a ModelResponse from the previous model.

        This method trims trailing ModelResponse messages to ensure compatibility.

        Args:
            messages: List of messages to validate/fix.

        Returns:
            List of messages guaranteed to end with ModelRequest, or empty list
            if no ModelRequest is found.
        """
        messages = list(messages)  # defensive copy
        if not messages:
            return messages

        # Trim trailing ModelResponse messages
        while messages and isinstance(messages[-1], ModelResponse):
            messages.pop()

        return messages

    # Message history processing methods (moved from state_management.py and message_history_processor.py)
    def _stringify_part(self, part: Any) -> str:
        """Create a stable string representation for a message part.

        We deliberately ignore timestamps so identical content hashes the same even when
        emitted at different times. This prevents status updates from blowing up the
        history when they are repeated with new timestamps."""

        # Bind attributes once to avoid repeated lookups
        role = getattr(part, "role", None)
        instructions = getattr(part, "instructions", None)
        tool_call_id = getattr(part, "tool_call_id", None)
        tool_name = getattr(part, "tool_name", None)
        content = getattr(part, "content", None)

        # Pre-size attributes list (class name + up to 6 optional attrs + content)
        attributes: list[str] = [part.__class__.__name__]

        # Role/instructions help disambiguate parts that otherwise share content
        if role:
            attributes.append(f"role={role}")
        if instructions:
            attributes.append(f"instructions={instructions}")
        if tool_call_id:
            attributes.append(f"tool_call_id={tool_call_id}")
        if tool_name:
            attributes.append(f"tool_name={tool_name}")

        # Handle content with faster isinstance checks instead of match
        if content is None:
            attributes.append("content=None")
        elif isinstance(content, str):
            attributes.append(f"content={content}")
        elif isinstance(content, pydantic.BaseModel):
            attributes.append(f"content={content.model_dump_json()}")
        elif isinstance(content, dict):
            attributes.append(f"content={json.dumps(content, sort_keys=True)}")
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, str):
                    attributes.append(f"content={item}")
                elif isinstance(item, BinaryContent):
                    # Use SHA-256 of full content for stable cross-process dedup
                    data = (
                        item.data
                        if isinstance(item.data, bytes)
                        else bytes(item.data)
                        if isinstance(item.data, (bytearray, memoryview))
                        else str(item.data).encode()
                    )
                    digest = hashlib.sha256(data).hexdigest()[:16]
                    attributes.append(f"BinaryContent={digest}:{len(data)}")
        else:
            attributes.append(f"content={content!r}")

        return "|".join(attributes)

    def hash_message(self, message: Any) -> str:
        """Create a stable hash for a model message that ignores timestamps.

        Uses SHA-256 (truncated to 16 hex chars) instead of Python's built-in
        hash() which randomizes per-process via PYTHONHASHSEED. This ensures
        hashes are stable across process restarts, which matters because
        _compacted_message_hashes is persisted to disk.
        """
        role = getattr(message, "role", None)
        instructions = getattr(message, "instructions", None)
        header_bits: list[str] = []
        if role:
            header_bits.append(f"role={role}")
        if instructions:
            header_bits.append(f"instructions={instructions}")

        part_strings = [
            self._stringify_part(part) for part in getattr(message, "parts", [])
        ]
        canonical = "||".join(header_bits + part_strings)
        return hashlib.sha256(canonical.encode()).hexdigest()[:16]

    def stringify_message_part(self, part) -> str:
        """
        Convert a message part to a string representation for token estimation or other uses.

        Args:
            part: A message part that may contain content or be a tool call

        Returns:
            String representation of the message part
        """
        # Bind attributes once to avoid repeated lookups
        part_kind = getattr(part, "part_kind", None)
        content = getattr(part, "content", None)
        tool_name = getattr(part, "tool_name", None)
        args = getattr(part, "args", None)

        # Build prefix with single concatenation
        prefix = f"{part_kind}: " if part_kind else f"{str(type(part))}: "

        # Handle content with faster isinstance checks instead of match
        if content:
            if isinstance(content, str):
                result = content
            elif isinstance(content, pydantic.BaseModel):
                result = content.model_dump_json()
            elif isinstance(content, dict):
                result = json.dumps(content)
            elif isinstance(content, list):
                result_parts = []
                for item in content:
                    if isinstance(item, str):
                        result_parts.append(item)
                    elif isinstance(item, BinaryContent):
                        # Estimate tokens based on actual binary size and media type
                        token_estimate = _estimate_binary_content_tokens(item)
                        # Cap to prevent absurd memory allocation
                        # 500K tokens ≈ max context window of any current model
                        token_estimate = min(token_estimate, 500_000)
                        # Create a placeholder string whose token count matches the estimate
                        placeholder = "X" * (token_estimate * 4)
                        result_parts.append(placeholder)
                result = "\n".join(result_parts)
            else:
                result = str(content)
        else:
            result = ""

        # Handle tool calls which may have additional token costs
        if tool_name:
            # Estimate tokens for tool name and parameters - single f-string
            tool_text = f"{tool_name} {args}" if args else tool_name
            result = f"{result}{tool_text}" if result else tool_text

        return f"{prefix}{result}" if result else prefix

    def estimate_token_count(self, text: str) -> int:
        """
        Simple token estimation using len(message) / 2.5.
        This replaces tiktoken with a much simpler approach.
        Delegates to the shared utility in token_utils for a single source of truth.
        """
        return _estimate_token_count(text)

    def estimate_tokens_for_message(self, message: ModelMessage) -> int:
        """
        Estimate the number of tokens in a message using len(message)
        Simple and fast replacement for tiktoken.
        """
        total_tokens = 0

        for part in message.parts:
            part_str = self.stringify_message_part(part)
            if part_str:
                total_tokens += self.estimate_token_count(part_str)

        return max(1, total_tokens)

    def estimate_context_overhead_tokens(self) -> int:
        """
        Estimate the token overhead from system prompt and tool definitions.

        This accounts for tokens that are always present in the context:
        - System prompt (for non-Claude-Code models)
        - Tool definitions (name, description, parameter schema)
        - MCP tool definitions

        Note: For Claude Code models, the system prompt is prepended to the first
        user message, so it's already counted in the message history tokens.
        We only count the short fixed instructions for Claude Code models.

        Results are cached per-instance and invalidated when the agent is reloaded
        (tool set and prompt change only on reload).
        """
        if self._state.cached_context_overhead is not None:
            return self._state.cached_context_overhead

        total_tokens = 0

        # 1. Estimate tokens for system prompt / instructions
        # Use prepare_prompt_for_model() to get the correct instructions for token counting.
        # For models that prepend system prompt to user message (claude-code, antigravity),
        # this returns the short fixed instructions. For other models, returns full prompt.
        try:
            from code_puppy.model_utils import prepare_prompt_for_model

            model_name = (
                self.get_model_name() if hasattr(self, "get_model_name") else ""
            )
            system_prompt = self.get_full_system_prompt()

            # Include puppy rules in estimation - they ARE included in actual requests
            puppy_rules = self.load_puppy_rules()
            if puppy_rules:
                system_prompt += f"\n{puppy_rules}"

            # Get the instructions that will be used (handles model-specific logic via hooks)
            prepared = prepare_prompt_for_model(
                model_name=model_name,
                system_prompt=system_prompt,
                user_prompt="",  # Empty - we just need the instructions
                prepend_system_to_user=False,  # Don't modify prompt, just get instructions
            )

            if prepared.instructions:
                total_tokens += self.estimate_token_count(prepared.instructions)
        except Exception:
            logger.debug(
                "Failed to get system prompt for token estimation", exc_info=True
            )

        # 2. Estimate tokens for code_generation_agent tool definitions
        pydantic_agent = self._state.code_generation_agent
        if pydantic_agent:
            tools = getattr(pydantic_agent, "_tools", None)
            if tools and isinstance(tools, dict):
                for tool_name, tool_func in tools.items():
                    try:
                        # Estimate tokens from tool name
                        total_tokens += self.estimate_token_count(tool_name)

                        # Estimate tokens from tool description
                        description = getattr(tool_func, "__doc__", None) or ""
                        if description:
                            total_tokens += self.estimate_token_count(description)

                        # Estimate tokens from parameter schema
                        # Tools may have a schema attribute or we can try to get it from annotations
                        schema = getattr(tool_func, "schema", None)
                        if schema:
                            # Use LRU cached serialization to avoid redundant JSON encoding
                            # Schemas are static, so caching eliminates repeated work
                            if isinstance(schema, dict):
                                schema_str = _serialize_schema_to_json(
                                    json.dumps(
                                        schema, sort_keys=True, separators=(",", ":")
                                    )
                                )
                            else:
                                schema_str = str(schema)
                            total_tokens += self.estimate_token_count(schema_str)
                        else:
                            # Try to get schema from function annotations
                            annotations = getattr(tool_func, "__annotations__", None)
                            if annotations:
                                total_tokens += self.estimate_token_count(
                                    str(annotations)
                                )
                    except Exception as e:
                        # Log at warning level for visibility; don't silently undercount
                        logger.warning(
                            "Failed to process tool %r for token counting: %s",
                            tool_name,
                            e,
                            exc_info=logger.isEnabledFor(logging.DEBUG),
                        )
                        # Fallback: estimate minimum tokens for tool name to avoid undercounting
                        total_tokens += self.estimate_token_count(tool_name) + 10
                        continue

        # 3. Estimate tokens for MCP tool definitions from cache
        # MCP tools are fetched asynchronously, so we use a cache that's populated
        # after the first successful run. See _update_mcp_tool_cache() method.
        mcp_tool_cache = (
            getattr(self, "_state", None) and self._state.mcp_tool_definitions_cache
        )
        if mcp_tool_cache:
            for tool_def in mcp_tool_cache:
                try:
                    # Estimate tokens from tool name
                    tool_name = tool_def.get("name", "")
                    if tool_name:
                        total_tokens += self.estimate_token_count(tool_name)

                    # Estimate tokens from tool description
                    description = tool_def.get("description", "")
                    if description:
                        total_tokens += self.estimate_token_count(description)

                    # Estimate tokens from parameter schema (inputSchema)
                    input_schema = tool_def.get("inputSchema")
                    if input_schema:
                        # Use LRU cached serialization for MCP tool schemas too
                        if isinstance(input_schema, dict):
                            schema_str = _serialize_schema_to_json(
                                json.dumps(
                                    input_schema, sort_keys=True, separators=(",", ":")
                                )
                            )
                        else:
                            schema_str = str(input_schema)
                        total_tokens += self.estimate_token_count(schema_str)
                except Exception as e:
                    # Log at warning level for visibility; don't silently undercount
                    try:
                        tool_name = tool_def.get("name", "unknown")
                    except Exception:
                        tool_name = "unknown"
                    logger.warning(
                        "Failed to process MCP tool %r for token counting: %s",
                        tool_name,
                        e,
                        exc_info=logger.isEnabledFor(logging.DEBUG),
                    )
                    # Fallback: estimate minimum tokens to avoid undercounting
                    total_tokens += self.estimate_token_count(tool_name) + 10
                    continue

        self._state.cached_context_overhead = total_tokens
        return total_tokens

    async def _update_mcp_tool_cache(self) -> None:
        """
        Update the MCP tool definitions cache by fetching tools from running MCP servers.

        This should be called after a successful run to populate the cache for
        accurate token estimation in subsequent runs.
        """
        mcp_servers = self._state.mcp_servers if self._state.mcp_servers else None
        if not mcp_servers:
            return

        tool_definitions = []
        for mcp_server in mcp_servers:
            try:
                # Check if the server has list_tools method (pydantic-ai MCP servers)
                if hasattr(mcp_server, "list_tools"):
                    # list_tools() returns list[mcp_types.Tool]
                    tools = await mcp_server.list_tools()
                    for tool in tools:
                        tool_def = {
                            "name": getattr(tool, "name", ""),
                            "description": getattr(tool, "description", ""),
                            "inputSchema": getattr(tool, "inputSchema", {}),
                        }
                        tool_definitions.append(tool_def)
            except Exception:
                logger.debug("MCP server not accessible, skipping", exc_info=True)
                continue

        self._state.mcp_tool_definitions_cache = tool_definitions
        # Invalidate context overhead cache when MCP tools change
        self._invalidate_token_caches()

    def update_mcp_tool_cache_sync(self) -> None:
        """
        Synchronously clear the MCP tool cache.

        This clears the cache so that token counts will be recalculated on the next
        agent run. Call this after starting/stopping MCP servers.

        Note: We don't try to fetch tools synchronously because MCP servers require
        async context management that doesn't work well from sync code. The cache
        will be repopulated on the next successful agent run.
        """
        # Simply clear the cache - it will be repopulated on the next agent run
        # This is safer than trying to call async methods from sync context
        self._state.mcp_tool_definitions_cache = []
        # Invalidate context overhead cache when MCP tools are cleared
        self._invalidate_token_caches()

    def _is_tool_call_part(self, part: Any) -> bool:
        if isinstance(part, (ToolCallPart, ToolCallPartDelta)):
            return True

        part_kind = (getattr(part, "part_kind", "") or "").replace("_", "-")
        if part_kind == "tool-call":
            return True

        has_tool_name = getattr(part, "tool_name", None) is not None
        has_args = getattr(part, "args", None) is not None
        has_args_delta = getattr(part, "args_delta", None) is not None

        return bool(has_tool_name and (has_args or has_args_delta))

    def _is_tool_return_part(self, part: Any) -> bool:
        if isinstance(part, (ToolReturnPart, ToolReturn)):
            return True

        part_kind = (getattr(part, "part_kind", "") or "").replace("_", "-")
        if part_kind in {"tool-return", "tool-result"}:
            return True

        if getattr(part, "tool_call_id", None) is None:
            return False

        has_content = getattr(part, "content", None) is not None
        has_content_delta = getattr(part, "content_delta", None) is not None
        return bool(has_content or has_content_delta)

    def _check_token_budgets(self, estimated_input: int) -> None:
        """Check hard token budgets before making an API call.

        Enforce per-session and per-run token limits.
        Raises RuntimeError if budgets are exceeded.
        """
        from code_puppy.config import get_max_run_tokens, get_max_session_tokens

        max_session = get_max_session_tokens()
        max_run = get_max_run_tokens()

        if max_session <= 0 and max_run <= 0:
            return

        ledger = self._state.get_token_ledger()
        session_total = ledger.total_estimated_input + ledger.total_estimated_output

        if max_session > 0 and session_total >= max_session:
            raise RuntimeError(
                f"Session token budget exceeded: {session_total} estimated tokens "
                f"(limit: {max_session}). Use /reset to start a new session."
            )

        if max_run > 0 and estimated_input >= max_run:
            raise RuntimeError(
                f"Run token budget exceeded: {estimated_input} estimated input tokens "
                f"(limit: {max_run}). Consider shorter prompts or /compact."
            )

    def _check_context_budget_before_send(
        self, prompt_payload: str | list[Any]
    ) -> None:
        """Pre-send assertion: validate context fits within model token budget.

        Raises RuntimeError if estimated tokens exceed the model's output limit,
        giving early warning before API call rather than mid-generation failure.

        This is part of context budget enforcement.
        """
        try:
            model_name = self.get_model_name()
            model_configs = ModelFactory.load_config()
            model_config = model_configs.get(model_name, {})
            max_output_tokens = resolve_max_output_tokens(model_name, model_config)
            context_length = int(model_config.get("context_length", 128000))
        except Exception:
            # Fallback if resolve_max_output_tokens unavailable or fails
            logger.debug("Could not resolve max_output_tokens, skipping budget check")
            return

        if max_output_tokens is None:
            return

        try:
            # Calculate current context size (overhead + message history)
            estimated_input = (
                self.estimate_context_overhead_tokens()
                + self._estimate_batch_tokens(self._message_history)
            )

            # Estimate prompt payload tokens
            if isinstance(prompt_payload, str):
                prompt_text = prompt_payload
            elif isinstance(prompt_payload, list):
                # Extract text from list payloads (attachments, etc)
                text_parts = []
                for item in prompt_payload:
                    if isinstance(item, str):
                        text_parts.append(item)
                    elif hasattr(item, "content"):
                        text_parts.append(str(getattr(item, "content", "")))
                prompt_text = "\n".join(text_parts)
            else:
                prompt_text = str(prompt_payload)

            estimated_prompt = self.estimate_token_count(prompt_text)
            total_estimated = estimated_input + estimated_prompt

            # Check: input + expected output must fit within context window
            safe_limit = int(context_length * 0.9)
            projected_total = total_estimated + max_output_tokens

            if projected_total > safe_limit:
                raise RuntimeError(
                    f"Context budget exceeded for {model_name}: "
                    f"estimated {total_estimated} input + {max_output_tokens} output = {projected_total} tokens "
                    f"(context: {context_length}, safe: {safe_limit}). "
                    f"Consider summarizing or clearing message history."
                )

            logger.debug(
                "Context budget check passed: %d input + %d output = %d/%d tokens",
                total_estimated,
                max_output_tokens,
                projected_total,
                context_length,
            )
        except Exception as exc:
            # Don't let budget check failures block the send
            if isinstance(exc, RuntimeError) and "budget exceeded" in str(exc):
                raise
            logger.debug("Context budget check failed silently: %s", exc)

    def filter_huge_messages(
        self,
        messages: list[ModelMessage],
        serialized_messages: list[dict] | None = None,
    ) -> list[ModelMessage]:
        """Filter out messages that exceed the token threshold.

        Args:
            messages: List of messages to filter
            serialized_messages: Unused (kept for API compatibility)

        Returns:
            Filtered list of messages
        """
        filtered = [m for m in messages if self.estimate_tokens_for_message(m) < 50000]
        # Pass serialized_messages through to avoid re-serialization
        pruned = self.prune_interrupted_tool_calls(
            filtered, serialized_messages=serialized_messages
        )
        return pruned

    def _find_safe_split_index(
        self, messages: list[ModelMessage], initial_split_idx: int
    ) -> int:
        """
        Adjust split index to avoid breaking tool_use/tool_result pairs.

        Ensures that if a tool_result is in the protected zone, its corresponding
        tool_use is also included. Otherwise the LLM will error with
        'tool_use ids found without tool_result blocks'.

        Args:
            messages: Full message list
            initial_split_idx: The initial split point (messages before this go to summarize)

        Returns:
            Adjusted split index that doesn't break tool pairs
        """
        if initial_split_idx <= 1:
            return initial_split_idx

        # Collect tool_call_ids from messages AFTER the split (protected zone)
        protected_tool_return_ids: set[str] = set()
        for msg in messages[initial_split_idx:]:
            for part in getattr(msg, "parts", None) or ():
                if getattr(part, "part_kind", None) == "tool-return":
                    tool_call_id = getattr(part, "tool_call_id", None)
                    if tool_call_id:
                        protected_tool_return_ids.add(tool_call_id)

        if not protected_tool_return_ids:
            return initial_split_idx

        # Scan backwards from split point to find any tool_uses that match protected returns
        adjusted_idx = initial_split_idx
        for i in range(
            initial_split_idx - 1, 0, -1
        ):  # Don't include system message at 0
            msg = messages[i]
            has_matching_tool_use = False
            for part in getattr(msg, "parts", None) or ():
                if getattr(part, "part_kind", None) == "tool-call":
                    tool_call_id = getattr(part, "tool_call_id", None)
                    if tool_call_id and tool_call_id in protected_tool_return_ids:
                        has_matching_tool_use = True
                        break

            if has_matching_tool_use:
                # This message has a tool_use whose return is in protected zone
                # Move the split point back to include this message in protected zone
                adjusted_idx = i
            else:
                # Once we find a message without matching tool_use, we can stop
                # (tool calls and returns should be adjacent)
                break

        return adjusted_idx

    def split_messages_for_protected_summarization(
        self,
        messages: list[ModelMessage],
        serialized_messages: list[dict] | None = None,
    ) -> tuple[list[ModelMessage], list[ModelMessage]]:
        """
        Split messages into two groups: messages to summarize and protected recent messages.

        Args:
            messages: Full message list to split
            serialized_messages: Unused (kept for API compatibility)

        Returns:
            Tuple of (messages_to_summarize, protected_messages)

        The protected_messages are the most recent messages that total up to the configured protected token count.
        The system message (first message) is always protected.
        All other messages that don't fit in the protected zone will be summarized.
        """
        if len(messages) <= 1:  # Just system message or empty
            return [], messages

        # Always protect the system message (first message)
        system_message = messages[0]
        system_tokens = self.estimate_tokens_for_message(system_message)

        if len(messages) == 1:
            return [], messages

        # Get the configured protected token count using model-aware fraction thresholds
        model_name = self.get_model_name()
        model_max = self.get_model_context_length()
        cfg = get_puppy_config()
        thresholds = compute_summarization_thresholds(
            model_name,
            trigger_fraction=cfg.summarization_trigger_fraction,
            keep_fraction=cfg.summarization_keep_fraction,
            absolute_trigger=int(
                cfg.compaction_threshold * model_max
            ),  # Convert proportion to tokens
            absolute_protected=cfg.protected_token_count,
        )
        # Use the keep_tokens (protected zone) from computed thresholds
        protected_tokens_limit = thresholds.keep_tokens

        # Calculate tokens for messages from most recent backwards (excluding system message)
        protected_messages = []
        protected_token_count = system_tokens  # Start with system message tokens

        # Go backwards through non-system messages to find protected zone
        for i in range(
            len(messages) - 1, 0, -1
        ):  # Stop at 1, not 0 (skip system message)
            message = messages[i]
            message_tokens = self.estimate_tokens_for_message(message)

            # If adding this message would exceed protected tokens, stop here
            if protected_token_count + message_tokens > protected_tokens_limit:
                break

            protected_messages.append(message)
            protected_token_count += message_tokens

        # Messages that were added while scanning backwards are currently in reverse order.
        # Reverse them to restore chronological ordering, then prepend the system prompt.
        protected_messages.reverse()
        protected_messages.insert(0, system_message)

        # Messages to summarize are everything between the system message and the
        # protected tail zone we just constructed.
        protected_start_idx = max(1, len(messages) - (len(protected_messages) - 1))

        # IMPORTANT: Adjust split point to avoid breaking tool_use/tool_result pairs
        # The LLM requires every tool_use to have its tool_result immediately after
        protected_start_idx = self._find_safe_split_index(messages, protected_start_idx)

        messages_to_summarize = messages[1:protected_start_idx]

        # Emit info messages
        emit_info(
            f"🔒 Protecting {len(protected_messages)} recent messages ({protected_token_count} tokens, limit: {protected_tokens_limit})"
        )
        emit_info(f"📝 Summarizing {len(messages_to_summarize)} older messages")

        return messages_to_summarize, protected_messages

    # Maximum recursion depth for binary-split summarization.
    # Each level halves the problem, so depth 4 handles histories up to ~16x
    # the summarizer's context window before falling back.
    _SUMMARIZE_MAX_DEPTH = 4

    # Summarization instructions shared by all summarization calls.
    _SUMMARIZE_INSTRUCTIONS = (
        "The input will be a log of Agentic AI steps that have been taken"
        " as well as user queries, etc. Summarize the contents of these steps."
        " The high level details should remain but the bulk of the content from tool-call"
        " responses should be compacted and summarized. For example if you see a tool-call"
        " reading a file, and the file contents are large, then in your summary you might just"
        " write: * used read_file on space_invaders.cpp - contents removed."
        "\n Make sure your result is a bulleted list of all steps and interactions."
        "\n\nNOTE: This summary represents older conversation history. Recent messages are preserved separately."
    )

    def _estimate_batch_tokens(self, messages: list[ModelMessage]) -> int:
        """Estimate total tokens for a batch of messages."""
        return sum(self.estimate_tokens_for_message(m) for m in messages)

    def _summarize_single_batch(
        self,
        messages_to_summarize: list[ModelMessage],
    ) -> list[ModelMessage]:
        """Run a single summarization call on a batch of messages.

        This is the low-level helper that calls run_summarization_sync.
        It prunes orphaned tool calls before sending and normalizes the
        return value to always be a list of ModelMessage.

        Raises:
            SummarizationError: If the LLM call fails.
        """
        pruned = self.prune_interrupted_tool_calls(messages_to_summarize)
        if not pruned:
            return []

        new_messages = run_summarization_sync(
            self._SUMMARIZE_INSTRUCTIONS, message_history=pruned
        )

        if not isinstance(new_messages, list):
            emit_warning(
                "Summarization agent returned non-list output; wrapping into message request"
            )
            new_messages = [ModelRequest([TextPart(str(new_messages))])]

        return list(new_messages)

    def _binary_split_summarize(
        self,
        messages_to_summarize: list[ModelMessage],
        depth: int = 0,
    ) -> list[ModelMessage]:
        """Recursively summarize messages using a binary-split strategy.

        When the messages to summarize exceed the summarizer model's context
        window, this method splits them in half, summarizes the first half,
        and checks whether the result plus the second half now fits. If not,
        it recurses on the combined result.

        This guarantees convergence because each recursion at least halves the
        input, bounded by ``_SUMMARIZE_MAX_DEPTH``.

        Args:
            messages_to_summarize: Messages to compress (system message NOT included).
            depth: Current recursion depth (callers should not set this).

        Returns:
            A list of summarized messages (without the system message prefix).

        Raises:
            SummarizationError: Propagated from the underlying LLM call.
        """
        if not messages_to_summarize:
            return []

        batch_tokens = self._estimate_batch_tokens(messages_to_summarize)

        # Use 80% of the summarizer's context as the safe threshold so we
        # leave room for the summarization instructions themselves.
        summarizer_limit = int(self.get_model_context_length() * 0.80)

        # Base case: the batch fits in a single summarization call, or we've
        # hit the maximum recursion depth and must attempt a best-effort call.
        if batch_tokens <= summarizer_limit or depth >= self._SUMMARIZE_MAX_DEPTH:
            if depth >= self._SUMMARIZE_MAX_DEPTH and batch_tokens > summarizer_limit:
                emit_warning(
                    f"Binary-split summarization hit max depth ({self._SUMMARIZE_MAX_DEPTH}). "
                    f"Attempting best-effort summarization of {batch_tokens} tokens "
                    f"(limit ~{summarizer_limit})."
                )
            return self._summarize_single_batch(messages_to_summarize)

        # Recursive case: split roughly in half.
        mid = len(messages_to_summarize) // 2

        # Adjust the split point to avoid breaking tool_use / tool_result
        # pairs. _find_safe_split_index expects a full message list with the
        # system message at index 0, so we temporarily prepend a placeholder.
        # Instead, we manually scan for tool-call boundaries near the midpoint.
        mid = self._find_safe_summarize_split(messages_to_summarize, mid)

        head = messages_to_summarize[:mid]
        tail = messages_to_summarize[mid:]

        # Edge case: if split produced an empty partition, just do best-effort.
        if not head or not tail:
            return self._summarize_single_batch(messages_to_summarize)

        emit_info(
            f"📐 Binary split (depth {depth + 1}): "
            f"summarizing first {len(head)} messages, "
            f"keeping {len(tail)} for next pass"
        )

        # Summarize the first half.
        summarized_head = self._summarize_single_batch(head)

        # Check whether the combined summary + tail now fits.
        combined = summarized_head + tail
        combined_tokens = self._estimate_batch_tokens(combined)

        if combined_tokens <= summarizer_limit:
            # It fits — done!
            return combined

        # Still too big — recurse on the combined result.
        return self._binary_split_summarize(combined, depth=depth + 1)

    def _find_safe_summarize_split(
        self,
        messages: list[ModelMessage],
        target_idx: int,
    ) -> int:
        """Find a safe split point near *target_idx* that doesn't break tool pairs.

        Scans backwards from *target_idx* to find a boundary where no
        tool_call in the first half has its tool_return in the second half.
        Falls back to *target_idx* if no better split is found within a
        reasonable window.
        """
        if target_idx <= 0:
            return target_idx

        # Collect tool_call_ids that appear AFTER the proposed split.
        tail_return_ids: set[str] = set()
        for msg in messages[target_idx:]:
            for part in getattr(msg, "parts", None) or ():
                if getattr(part, "part_kind", None) == "tool-return":
                    tid = getattr(part, "tool_call_id", None)
                    if tid:
                        tail_return_ids.add(tid)

        if not tail_return_ids:
            return target_idx

        # Walk backwards looking for a position where no tool_call in head
        # has its return in the tail.
        for candidate in range(target_idx, max(target_idx - 10, 0), -1):
            head_call_ids: set[str] = set()
            for msg in messages[:candidate]:
                for part in getattr(msg, "parts", None) or ():
                    if getattr(part, "part_kind", None) == "tool-call":
                        tid = getattr(part, "tool_call_id", None)
                        if tid:
                            head_call_ids.add(tid)
            if not head_call_ids.intersection(tail_return_ids):
                return candidate

        # Couldn't find a clean break — use the original target.
        return target_idx

    def summarize_messages(
        self,
        messages: list[ModelMessage],
        with_protection: bool = True,
        serialized_messages: list[dict] | None = None,
    ) -> tuple[list[ModelMessage], list[ModelMessage]]:
        """Summarize messages while protecting recent messages up to PROTECTED_TOKENS.

        Uses a binary-split strategy: when the messages to summarize exceed
        the summarizer's context window, the batch is recursively split in
        half, each half summarized independently, and the results combined.
        This guarantees convergence for arbitrarily large histories.

        Enhanced with:
        - Pre-truncation of tool call arguments (cheap token reclamation)
        - History offload to file (opt-in debugging)
        - Model-aware fraction thresholds

        Args:
            messages: Messages to summarize
            with_protection: Whether to protect recent messages
            serialized_messages: Unused (kept for API compatibility)

        Returns:
            Tuple of (compacted_messages, summarized_source_messages)
            where compacted_messages always preserves the original system message
            as the first entry.
        """
        if not messages:
            return [], []

        # --- Phase 1: Pre-truncation of tool call args (cheap token reclamation) ---
        cfg = get_puppy_config()
        if cfg.summarization_pretruncate_enabled:
            try:
                max_arg_len = cfg.summarization_arg_max_length
                max_ret_len = cfg.summarization_return_max_length
                ret_head = cfg.summarization_return_head_chars
                ret_tail = cfg.summarization_return_tail_chars
                truncated_msgs, trunc_count = pretruncate_messages(
                    messages,
                    keep_recent=10,
                    max_length=max_arg_len,
                    max_return_length=max_ret_len,
                    return_head_chars=ret_head,
                    return_tail_chars=ret_tail,
                )
                if trunc_count > 0:
                    emit_info(
                        f"✂️ Pre-truncated {trunc_count} messages (args > {max_arg_len}, returns > {max_ret_len} chars)"
                    )
                messages = truncated_msgs
            except Exception as e:
                # Don't fail summarization if pre-truncation errors
                logger.debug("Pre-truncation failed, continuing: %s", e)

        messages_to_summarize: list[ModelMessage]
        protected_messages: list[ModelMessage]

        if with_protection:
            messages_to_summarize, protected_messages = (
                self.split_messages_for_protected_summarization(
                    messages, serialized_messages=serialized_messages
                )
            )
        else:
            messages_to_summarize = messages[1:] if messages else []
            protected_messages = messages[:1]

        if not messages_to_summarize:
            # Nothing to summarize, so just return the original sequence
            # Pass serialized_messages to avoid re-serialization
            return self.prune_interrupted_tool_calls(
                messages, serialized_messages=serialized_messages
            ), []

        system_message = messages[0]

        # --- Phase 2: History offload (opt-in debugging) ---
        if cfg.summarization_history_offload_enabled:
            try:
                # Handle explicit session_id=None using `or 'unknown'` before sanitization
                session_id = getattr(self, "session_id", None) or "unknown"
                history_dir = cfg.summarization_history_dir
                offload_path = offload_evicted_messages(
                    messages_to_summarize,
                    session_id=session_id,
                    archive_dir=history_dir,
                    compact_reason="summarization",
                )
                if offload_path:
                    emit_info(
                        f"📦 Offloaded {len(messages_to_summarize)} messages to {offload_path}"
                    )
            except Exception as e:
                # Don't fail summarization if offload errors
                logger.debug("History offload failed, continuing: %s", e)

        try:
            new_messages = self._binary_split_summarize(messages_to_summarize)

            if not new_messages:
                # Summarization produced nothing (e.g., all messages pruned)
                # Pass serialized_messages to avoid re-serialization
                return self.prune_interrupted_tool_calls(
                    messages, serialized_messages=serialized_messages
                ), []

            compacted: list[ModelMessage] = [system_message] + new_messages

            # Drop the system message from protected_messages because we already included it
            protected_tail = [
                msg for msg in protected_messages if msg is not system_message
            ]

            compacted.extend(protected_tail)

            return self.prune_interrupted_tool_calls(compacted), messages_to_summarize
        except SummarizationError as e:
            # SummarizationError has detailed error info
            emit_error(f"Summarization failed: {e}")
            if e.original_error:
                emit_warning(
                    f"\U0001f4a1 Tip: Underlying error was {type(e.original_error).__name__}. "
                    "Consider using '/set compaction_strategy=truncation' as a fallback."
                )
            return messages, []  # Return original messages on failure
        except Exception as e:
            # Catch-all for unexpected errors
            error_type = type(e).__name__
            error_msg = str(e) if str(e) else "(no error details)"
            emit_error(
                f"Unexpected error during compaction: [{error_type}] {error_msg}"
            )
            return messages, []  # Return original messages on failure

    def get_model_context_length(self) -> int:
        """
        Return the context length for this agent's effective model.

        Honors per-agent pinned model via `self.get_model_name()`; falls back
        to global model when no pin is set. Defaults conservatively on failure.
        """
        try:
            model_configs = ModelFactory.load_config()
            # Use the agent's effective model (respects /pin_model)
            model_name = self.get_model_name()
            model_config = model_configs.get(model_name, {})
            context_length = model_config.get("context_length", 128000)
            return int(context_length)
        except Exception:
            logger.debug(
                "Model context lookup failed, using default 128000", exc_info=True
            )
            return 128000

    @staticmethod
    def _collect_tool_call_ids_uncached(
        messages: list[ModelMessage],
    ) -> tuple[set[str], set[str]]:
        """Collect tool_call_ids and tool_return_ids from messages (no caching)."""
        call_ids: set[str] = set()
        return_ids: set[str] = set()
        for msg in messages:
            for part in getattr(msg, "parts", None) or ():
                tcid = getattr(part, "tool_call_id", None)
                if not tcid:
                    continue
                if part.part_kind == "tool-call":
                    call_ids.add(tcid)
                else:
                    return_ids.add(tcid)
        return call_ids, return_ids

    def _collect_tool_call_ids(
        self,
        messages: list[ModelMessage],
    ) -> tuple[set[str], set[str]]:
        """Collect tool_call_ids and tool_return_ids with per-list caching.

        Caches result keyed by content-based hash of messages so repeated
        calls within a single message_history_processor invocation reuse
        the previous scan. The cache is invalidated automatically when
        a different list or content is seen.
        """
        # Compute content-based cache key using message hashes
        import hashlib

        hasher = hashlib.sha256()
        hasher.update(str(len(messages)).encode())
        for msg in messages:
            hasher.update(self.hash_message(msg).encode())
        cache_key = hasher.hexdigest()[:32]  # 128 bits is sufficient
        if (
            self._state.tool_ids_cache is not None
            and self._state.tool_ids_cache[0] == cache_key
        ):
            return self._state.tool_ids_cache[1]
        result = self._collect_tool_call_ids_uncached(messages)
        self._state.tool_ids_cache = (cache_key, result)
        return result

    def _check_pending_tool_calls(
        self, messages: list[ModelMessage]
    ) -> tuple[bool, int]:
        """Check for pending tool calls and return both existence flag and count.

        This single-pass method returns both whether there are pending tool calls
        and how many, avoiding duplicate traversal when both values are needed.

        Args:
            messages: Message history to check

        Returns:
            Tuple of (has_pending: bool, pending_count: int)
        """
        if not messages:
            return False, 0
        tool_call_ids, tool_return_ids = self._collect_tool_call_ids(messages)
        pending = tool_call_ids - tool_return_ids
        return bool(pending), len(pending)

    def has_pending_tool_calls(self, messages: list[ModelMessage]) -> bool:
        """
        Check if there are any pending tool calls in the message history.

        A pending tool call is one that has a ToolCallPart without a corresponding
        ToolReturnPart. This indicates the model is still waiting for tool execution.

        Returns:
            True if there are pending tool calls, False otherwise
        """
        return self._check_pending_tool_calls(messages)[0]

    def request_delayed_compaction(self) -> None:
        """
        Request that compaction be attempted after the current tool calls complete.

        This sets a per-instance flag that will be checked during the next message
        processing cycle to trigger compaction when it's safe to do so.
        """
        self._state.delayed_compaction_requested = True
        emit_info(
            "🔄 Delayed compaction requested - will attempt after tool calls complete",
            message_group="token_context_status",
        )

    def should_attempt_delayed_compaction(self) -> bool:
        """
        Check if delayed compaction was requested and it's now safe to proceed.

        Returns:
            True if delayed compaction was requested and no tool calls are pending
        """
        if not self._state.delayed_compaction_requested:
            return False

        # Check if it's now safe to compact
        messages = self.get_message_history()
        if not self.has_pending_tool_calls(messages):
            self._state.delayed_compaction_requested = False  # Reset the flag
            return True

        return False

    def compact_messages(
        self, messages: list[ModelMessage]
    ) -> tuple[list[ModelMessage], dict]:
        """Compact message history for delayed compaction.

        Called when delayed compaction is triggered after tool calls complete.
        Uses truncation to bring the context within the model's context window.

        Args:
            messages: Current message history to compact.

        Returns:
            Tuple of (compacted_messages, metadata_dict). On error, returns
            the original messages unchanged so the agent can continue running.
        """
        model_max = self.get_model_context_length()
        # Protect ~25% of context window for the upcoming response
        protected_tokens = model_max // 4
        try:
            compacted = self.truncation(messages, protected_tokens=protected_tokens)
            return compacted, {
                "method": "truncation",
                "original_count": len(messages),
                "compacted_count": len(compacted),
            }
        except Exception as exc:
            logger.debug(
                "compact_messages: truncation failed, returning original: %s", exc
            )
            return messages, {"method": "noop", "error": str(exc)}

    def get_pending_tool_call_count(self, messages: list[ModelMessage]) -> int:
        """
        Get the count of pending tool calls for debugging purposes.

        Returns:
            Number of tool calls waiting for execution
        """
        return self._check_pending_tool_calls(messages)[1]

    def prune_interrupted_tool_calls(
        self,
        messages: list[ModelMessage],
        serialized_messages: list[dict] | None = None,
    ) -> list[ModelMessage]:
        """
        Remove any messages that participate in mismatched tool call sequences.

        A mismatched tool call id is one that appears in a ToolCall (model/tool request)
        without a corresponding tool return, or vice versa. We preserve original order
        and only drop messages that contain parts referencing mismatched tool_call_ids.

        Args:
            messages: List of messages to prune
            serialized_messages: Unused (kept for API compatibility)

        Returns:
            Pruned list of messages with mismatched tool calls removed
        """
        if not messages:
            return messages
        tool_call_ids, tool_return_ids = self._collect_tool_call_ids(messages)
        mismatched: set[str] = tool_call_ids.symmetric_difference(tool_return_ids)
        if not mismatched:
            return messages

        pruned: list[ModelMessage] = []
        dropped_count = 0
        for msg in messages:
            has_mismatched = False
            for part in getattr(msg, "parts", None) or ():
                tcid = getattr(part, "tool_call_id", None)
                if tcid and tcid in mismatched:
                    has_mismatched = True
                    break
            if has_mismatched:
                dropped_count += 1
                continue
            pruned.append(msg)

        # Shadow mode: compare with Elixir implementation
        shadow_prune_and_filter(messages, pruned)

        return pruned

    def message_history_processor(
        self, ctx: RunContext, messages: list[ModelMessage]
    ) -> list[ModelMessage]:
        """Process message history for context management.

        Returns the processed message list after compaction/truncation.
        """
        # First, prune any interrupted/mismatched tool-call conversations
        model_max = self.get_model_context_length()

        message_tokens = sum(self.estimate_tokens_for_message(msg) for msg in messages)
        context_overhead = self.estimate_context_overhead_tokens()
        total_current_tokens = message_tokens + context_overhead
        proportion_used = total_current_tokens / model_max

        context_summary = SpinnerBase.format_context_info(
            total_current_tokens, model_max, proportion_used
        )
        update_spinner_context(context_summary)

        # Get config for compaction settings
        cfg = get_puppy_config()

        # Get the configured compaction threshold
        compaction_threshold = cfg.compaction_threshold

        # Get the configured compaction strategy
        compaction_strategy = get_compaction_strategy()

        if proportion_used > compaction_threshold:
            # RACE CONDITION PROTECTION: Check for pending tool calls before summarization
            if compaction_strategy == "summarization":
                has_pending, pending_count = self._check_pending_tool_calls(messages)
                if has_pending:
                    emit_warning(
                        f"⚠️ Summarization deferred: {pending_count} pending tool call(s) detected. "
                        "Waiting for tool execution to complete before compaction.",
                        message_group="token_context_status",
                    )
                    # Request delayed compaction for when tool calls complete
                    self.request_delayed_compaction()
                    # Return original messages without compaction
                    return messages

            if compaction_strategy == "truncation":
                # Use truncation instead of summarization
                protected_tokens = cfg.protected_token_count
                filtered_messages = self.filter_huge_messages(messages)
                result_messages = self.truncation(
                    filtered_messages,
                    protected_tokens,
                )
                # Track dropped messages by hash so message_history_accumulator
                # won't re-inject them from pydantic-ai's full message list on
                # subsequent calls within the same run (fixes ghost-task bug).
                result_hashes = {self.hash_message(m) for m in result_messages}
                summarized_messages = [
                    m
                    for m in filtered_messages
                    if self.hash_message(m) not in result_hashes
                ]
                # Calculate final token count
                final_token_count = sum(
                    self.estimate_tokens_for_message(msg) for msg in result_messages
                )
            else:
                # Default to summarization (safe to proceed - no pending tool calls)
                filtered_messages = self.filter_huge_messages(messages)
                result_messages, summarized_messages = self.summarize_messages(
                    filtered_messages,
                )
                # For summarization, we need to estimate tokens since messages are transformed
                final_token_count = sum(
                    self.estimate_tokens_for_message(msg) for msg in result_messages
                )

            # Update spinner with final token count
            final_summary = SpinnerBase.format_context_info(
                final_token_count, model_max, final_token_count / model_max
            )
            update_spinner_context(final_summary)

            self.set_message_history(result_messages)
            for m in summarized_messages:
                self.add_compacted_message_hash(self.hash_message(m))
            return result_messages
        return messages

    def truncation(
        self,
        messages: list[ModelMessage],
        protected_tokens: int,
        per_message_tokens: list[int | None] = None,
    ) -> list[ModelMessage]:
        """
        Truncate message history to manage token usage.

        Protects:
        - The first message (system prompt) - always kept
        - The second message if it contains thinking parts (kept for reasoning models)
        - Recent messages up to protected_tokens limit

        Args:
            messages: List of messages to truncate
            protected_tokens: Number of tokens to protect
            per_message_tokens: Optional pre-computed per-message token counts.
                When provided (e.g., from message_history_processor), avoids
                re-serializing and re-computing token counts.

        Returns:
            Truncated list of messages
        """
        emit_info("Truncating message history to manage token usage")
        result = [messages[0]]
        skip_second = False
        if len(messages) > 1:
            second_msg = messages[1]
            has_thinking = any(
                isinstance(part, ThinkingPart) for part in second_msg.parts
            )
            if has_thinking:
                result.append(second_msg)
                skip_second = True

        num_tokens = 0
        kept: list = []
        start_idx = 2 if skip_second else 1
        messages_to_scan = messages[start_idx:]

        use_cached = per_message_tokens is not None and len(per_message_tokens) == len(
            messages
        )
        for i, msg in enumerate(reversed(messages_to_scan)):
            orig_idx = len(messages) - 1 - i
            if use_cached and per_message_tokens[orig_idx] is not None:
                num_tokens += per_message_tokens[orig_idx]
            else:
                num_tokens += self.estimate_tokens_for_message(msg)
            if num_tokens > protected_tokens:
                break
            kept.append(msg)

        result.extend(reversed(kept))

        result = self.prune_interrupted_tool_calls(result)
        return result

    def run_summarization_sync(
        self, instructions: str, message_history: list[ModelMessage]
    ) -> list[ModelMessage] | str:
        """
        Run summarization synchronously using the configured summarization agent.
        This is exposed as a method so it can be overridden by subclasses if needed.

        Args:
            instructions: Instructions for the summarization agent
            message_history: List of messages to summarize

        Returns:
            Summarized messages or text
        """
        return run_summarization_sync(instructions, message_history)

    # ===== Agent wiring formerly in code_puppy/agent.py =====
    def load_puppy_rules(self) -> str | None:
        """Load AGENT(S).md from both global config and project directory.

        Checks for AGENTS.md/AGENT.md/agents.md/agent.md in this order:
        1. Global config directory (~/.code_puppy/ or XDG config)
        2. Current working directory (project-specific)

        If both exist, they are combined with global rules first, then project rules.
        This allows project-specific rules to override or extend global rules.
        """
        if self._state.puppy_rules is not None:
            return self._state.puppy_rules
        from pathlib import Path

        possible_paths = ["AGENTS.md", "AGENT.md", "agents.md", "agent.md"]

        # Load global rules from CONFIG_DIR
        global_rules = None
        from code_puppy.config import CONFIG_DIR

        for path_str in possible_paths:
            global_path = Path(CONFIG_DIR) / path_str
            try:
                global_rules = global_path.read_text(encoding="utf-8-sig")
                break
            except FileNotFoundError:
                continue

        # Load project-local rules from current working directory
        project_rules = None
        for path_str in possible_paths:
            project_path = Path(path_str)
            try:
                project_rules = project_path.read_text(encoding="utf-8-sig")
                break
            except FileNotFoundError:
                continue

        # Combine global and project rules
        # Global rules come first, project rules second (allowing project to override)
        rules = [r for r in [global_rules, project_rules] if r]
        self._state.puppy_rules = "\n\n".join(rules) if rules else None
        return self._state.puppy_rules

    def load_mcp_servers(self, extra_headers: dict[str, str | None] = None):
        """Load MCP servers through the manager and return pydantic-ai compatible servers.

        Note: The manager automatically syncs from mcp_servers.json during initialization,
        so we don't need to sync here. Use reload_mcp_servers() to force a re-sync.
        """

        mcp_disabled = get_value("disable_mcp_servers")
        if mcp_disabled and str(mcp_disabled).lower() in ("1", "true", "yes", "on"):
            return []

        manager = get_mcp_manager()
        return manager.get_servers_for_agent()

    def reload_mcp_servers(self):
        """Reload MCP servers and return updated servers.

        Forces a re-sync from mcp_servers.json to pick up any configuration changes.
        """
        # Clear the MCP tool cache when servers are reloaded
        self._state.mcp_tool_definitions_cache = []
        # MCP tools are part of context overhead — invalidate token caches
        # to prevent stale estimates after tool changes
        self._invalidate_token_caches()

        # Force re-sync from mcp_servers.json
        manager = get_mcp_manager()
        manager.sync_from_config()

        return manager.get_servers_for_agent()

    def _load_model_with_fallback(
        self,
        requested_model_name: str,
        models_config: dict[str, Any],
        message_group: str,
    ) -> tuple[Any, str]:
        """Load the requested model, applying a friendly fallback when unavailable."""
        try:
            model = ModelFactory.get_model(requested_model_name, models_config)
            return model, requested_model_name
        except ValueError as exc:
            available_models = list(models_config.keys())
            available_str = (
                ", ".join(sorted(available_models))
                if available_models
                else "no configured models"
            )
            emit_warning(
                (
                    f"Model '{requested_model_name}' not found. "
                    f"Available models: {available_str}"
                ),
                message_group=message_group,
            )

            fallback_candidates: list[str] = []
            global_candidate = get_global_model_name()
            if global_candidate:
                fallback_candidates.append(global_candidate)

            for candidate in available_models:
                if candidate not in fallback_candidates:
                    fallback_candidates.append(candidate)

            for candidate in fallback_candidates:
                if not candidate or candidate == requested_model_name:
                    continue
                try:
                    model = ModelFactory.get_model(candidate, models_config)
                    emit_info(
                        f"Using fallback model: {candidate}",
                        message_group=message_group,
                    )
                    return model, candidate
                except ValueError:
                    continue

            friendly_message = (
                "No valid model could be loaded. Update the model configuration or set "
                "a valid model with `config set`."
            )
            emit_error(friendly_message, message_group=message_group)
            raise ValueError(friendly_message) from exc

    def _build_agent(
        self,
        output_type: type = str,
        message_group: str | None = None,
        mcp_servers: list | None = None,
    ) -> tuple[Any, str, list, Any, str, Any]:
        """Build a configured PydanticAgent with the given output type.

        This is the shared construction logic used by both
        ``reload_code_generation_agent`` and ``_create_agent_with_output_type``.

        Args:
            output_type: The output type for the agent (default ``str``).
            message_group: Optional message group for logging; auto-generated
                if omitted.
            mcp_servers: MCP server toolsets to use. Pass ``None`` (default)
                to reuse the cached ``self._mcp_servers``, or pass an explicit
                list (e.g. freshly loaded servers for a reload).

        Returns:
            Tuple of ``(pydantic_agent, resolved_model_name, mcp_servers,
            model, instructions, model_settings)``.
        """
        from code_puppy.model_utils import prepare_prompt_for_model
        from code_puppy.tools import (
            EXTENDED_THINKING_PROMPT_NOTE,
            has_extended_thinking_active,
            register_tools_for_agent,
        )

        if message_group is None:
            message_group = str(uuid.uuid4())

        model_name = self.get_model_name()
        models_config = ModelFactory.load_config()
        model, resolved_model_name = self._load_model_with_fallback(
            model_name, models_config, message_group
        )

        instructions = self.get_full_system_prompt()
        puppy_rules = self.load_puppy_rules()
        if puppy_rules:
            instructions += f"\n{puppy_rules}"

        if mcp_servers is None:
            mcp_servers = getattr(self, "_mcp_servers", None) or ()

        model_settings = make_model_settings(resolved_model_name)

        # When extended thinking is active, nudge the model to think between
        # tool calls so it uses native reasoning before choosing next actions.
        if has_extended_thinking_active(resolved_model_name):
            instructions += EXTENDED_THINKING_PROMPT_NOTE

        # Handle claude-code models: swap instructions (prompt prepending
        # happens in run_with_mcp).
        prepared = prepare_prompt_for_model(
            model_name, instructions, "", prepend_system_to_user=False
        )
        instructions = prepared.instructions

        p_agent = PydanticAgent(
            model=model,
            instructions=instructions,
            output_type=output_type,
            retries=3,
            toolsets=[] if get_use_dbos() else mcp_servers,
            history_processors=[self.message_history_accumulator],
            model_settings=model_settings,
        )

        agent_tools = self.get_available_tools()
        register_tools_for_agent(p_agent, agent_tools, model_name=resolved_model_name)

        self._state.cur_model = model
        return (
            p_agent,
            resolved_model_name,
            mcp_servers,
            model,
            instructions,
            model_settings,
        )

    def reload_code_generation_agent(self, message_group: str | None = None):
        """Force-reload the pydantic-ai Agent based on current config and model."""
        # Invalidate the project-local rules cache so a fresh read from the
        # current working directory is performed on the next load_puppy_rules()
        # call. This is critical for /cd: the user may have switched to a
        # different project that has its own AGENT.md (or none at all).
        self._state.puppy_rules = None
        # Invalidate ALL token caches since agent reload changes tools/prompt
        self._state.invalidate_all_token_caches()
        # Invalidate resolved model components cache since model/tools may change
        self._state.resolved_model_components_cache = None

        # Build agent with freshly-loaded MCP servers so we can inspect its
        # registered tool names for conflict filtering.
        fresh_mcp = self.load_mcp_servers()
        (
            p_agent,
            resolved_model_name,
            mcp_servers,
            model,
            instructions,
            model_settings,
        ) = self._build_agent(
            output_type=str, message_group=message_group, mcp_servers=fresh_mcp
        )

        # Get existing tool names to filter out conflicts with MCP tools
        existing_tool_names = set()
        try:
            # Get tools from the agent to find existing tool names
            tools = getattr(p_agent, "_tools", None)
            if tools:
                existing_tool_names = set(tools.keys())
        except Exception:
            logger.debug("Failed to get tool names for filtering", exc_info=True)

        # Filter MCP server toolsets to remove conflicting tools
        filtered_mcp_servers = []
        if mcp_servers and existing_tool_names:
            for mcp_server in mcp_servers:
                try:
                    # Get tools from this MCP server
                    server_tools = getattr(mcp_server, "tools", None)
                    if server_tools:
                        # Filter out conflicting tools
                        filtered_tools = {}
                        for tool_name, tool_func in server_tools.items():
                            if tool_name not in existing_tool_names:
                                filtered_tools[tool_name] = tool_func

                        # Create a filtered version of the MCP server if we have tools
                        if filtered_tools:
                            # Create a new toolset with filtered tools
                            from pydantic_ai.tools import ToolSet

                            filtered_toolset = ToolSet()
                            for tool_name, tool_func in filtered_tools.items():
                                filtered_toolset._tools[tool_name] = tool_func
                            filtered_mcp_servers.append(filtered_toolset)
                        else:
                            # No tools left after filtering, skip this server
                            pass
                    else:
                        # Can't get tools from this server, include as-is
                        filtered_mcp_servers.append(mcp_server)
                except Exception:
                    # Error processing this server, include as-is to be safe
                    filtered_mcp_servers.append(mcp_server)
        else:
            # No filtering needed or possible
            filtered_mcp_servers = mcp_servers if mcp_servers else []

        if len(filtered_mcp_servers) != len(mcp_servers):
            emit_info(
                Text.from_markup(
                    f"[dim]Filtered {len(mcp_servers) - len(filtered_mcp_servers)} conflicting MCP tools[/dim]"
                )
            )

        self._state.last_model_name = resolved_model_name
        # Wrap with DBOS, but handle MCP servers separately to avoid
        # serialization issues ("cannot pickle async_generator object").
        global _reload_count
        _reload_count += 1
        if get_use_dbos():
            # p_agent was built with toolsets=[] (DBOS path in _build_agent).
            # Wrap with DBOS and store filtered MCP servers for runtime use.
            dbos_agent = DBOSAgent(
                p_agent,
                name=f"{self.name}-{_reload_count}",
                event_stream_handler=event_stream_handler,
            )
            self._state.cur_model = dbos_agent
            self._state.code_generation_agent = dbos_agent
            self._state.mcp_servers = filtered_mcp_servers
        else:
            # Non-DBOS path: recreate agent with filtered MCP servers.
            # Reuse model/instructions/model_settings from the first _build_agent
            # call so _load_model_with_fallback is only called once.
            from code_puppy.tools import register_tools_for_agent

            final_agent = PydanticAgent(
                model=model,
                instructions=instructions,
                output_type=str,
                retries=3,
                toolsets=filtered_mcp_servers,
                history_processors=[self.message_history_accumulator],
                model_settings=model_settings,
            )
            agent_tools = self.get_available_tools()
            register_tools_for_agent(
                final_agent, agent_tools, model_name=resolved_model_name
            )
            self._state.cur_model = final_agent
            self._state.code_generation_agent = final_agent
            self._state.mcp_servers = filtered_mcp_servers
        return self._state.code_generation_agent

    def _create_agent_with_output_type(self, output_type: type[Any]) -> PydanticAgent:
        """Create a temporary agent configured with a custom output_type.

        This is used when structured output is requested via run_with_mcp.
        The agent is created fresh with the same configuration as the main agent
        but with the specified output_type instead of str.

        Uses cached MCP servers (``self._mcp_servers``) so the set of tools
        is consistent with the currently loaded code-generation agent.

        Resolved model components are cached per output_type to avoid
        re-resolution on repeated calls.

        Args:
            output_type: The Pydantic model or type for structured output.

        Returns:
            A configured PydanticAgent (or DBOSAgent wrapper) with the custom output_type.
        """
        # Initialize cache dict if needed
        if self._state.resolved_model_components_cache is None:
            self._state.resolved_model_components_cache = {}

        # Check cache for resolved components keyed by output_type
        cache_key = output_type if isinstance(output_type, type) else str(output_type)
        if cache_key in self._state.resolved_model_components_cache:
            cached = self._state.resolved_model_components_cache[cache_key]
            p_agent = cached["p_agent"]
        else:
            # Reuse cached MCP servers from the last reload.
            mcp_servers = self._state.mcp_servers or []
            p_agent, resolved_model_name, _, _model, _instructions, _model_settings = (
                self._build_agent(
                    output_type=output_type,
                    mcp_servers=mcp_servers,
                )
            )
            # Cache the resolved components
            self._state.resolved_model_components_cache[cache_key] = {
                "p_agent": p_agent,
                "resolved_model_name": resolved_model_name,
            }

        global _reload_count
        _reload_count += 1

        if get_use_dbos():
            # Pass event_stream_handler at construction time for streaming output.
            dbos_agent = DBOSAgent(
                p_agent,
                name=f"{self.name}-structured-{_reload_count}",
                event_stream_handler=event_stream_handler,
            )
            return dbos_agent
        else:
            return p_agent

    # It's okay to decorate it with DBOS.step even if not using DBOS; the decorator is a no-op in that case.
    @(DBOS.step() if DBOS is not None else lambda f: f)
    def message_history_accumulator(self, ctx: RunContext, messages: list[Any]):
        _message_history = self.get_message_history()

        # Hook: on_message_history_processor_start - dump the message history before processing
        # Use count_callbacks() for cheap check before expensive list copying
        if count_callbacks("message_history_processor_start"):
            on_message_history_processor_start(
                agent_name=self.name,
                session_id=getattr(self, "session_id", None),
                message_history=list(_message_history),  # Copy to avoid mutation issues
                incoming_messages=list(messages),
            )
        # Use Python hashing for dedup in the accumulator.
        # We must stay in the same hash domain as compacted_message_hashes
        # (which are accumulated over turns using Python hash()). Rust
        # acceleration is applied in message_history_processor for token
        # estimation — that's where the big speedup lives.
        # Use the incrementally-maintained hash set instead of rebuilding
        # from scratch each turn (was O(n*p), now O(1)).
        message_history_hashes = self._state.message_history_hashes
        messages_added = 0
        last_msg_index = len(messages) - 1
        for i, msg in enumerate(messages):
            msg_hash = self.hash_message(msg)
            if msg_hash not in message_history_hashes:
                # Always preserve the last message (the user's new prompt) even
                # if its hash matches a previously compacted/summarized message.
                # Short or repeated prompts (e.g. "yes", "1") can collide with
                # compacted hashes, which would silently drop the user's input
                # and leave the history ending with a ModelResponse. That
                # triggers an Anthropic API error: "This model does not support
                # assistant message prefill."
                if (
                    i == last_msg_index
                    or msg_hash not in self.get_compacted_message_hashes()
                ):
                    _message_history.append(msg)
                    messages_added += 1

        # Apply message history trimming using the main processor
        # This ensures we maintain global state while still managing context limits
        self.message_history_processor(ctx, _message_history)
        result_messages_filtered_empty_thinking = []
        filtered_count = 0
        for msg in self.get_message_history():
            # Single-pass filter: build filtered list and track if any changes
            original_parts = msg.parts
            new_parts = []
            found_empty_thinking = False
            for p in original_parts:
                if isinstance(p, ThinkingPart) and not p.content:
                    found_empty_thinking = True
                else:
                    new_parts.append(p)

            if found_empty_thinking:
                # All parts were empty thinking - filter entire message
                if not new_parts:
                    filtered_count += 1
                    continue
                # Partial filter - rebuild message with remaining parts
                msg = dataclasses.replace(msg, parts=new_parts)
            # else: no changes needed, use msg as-is (parts identical)
            result_messages_filtered_empty_thinking.append(msg)
        self.set_message_history(result_messages_filtered_empty_thinking)

        # Safety net: ensure history always ends with a ModelRequest.
        # If compaction or filtering somehow leaves a trailing ModelResponse,
        # the Anthropic API will reject it with a prefill error.
        final_history = self.ensure_history_ends_with_request(
            self.get_message_history()
        )
        if final_history != self.get_message_history():
            self.set_message_history(final_history)

        # Hook: on_message_history_processor_end - dump the message history after processing
        # Use count_callbacks() for cheap check before expensive list copying
        if count_callbacks("message_history_processor_end"):
            messages_filtered = len(messages) - messages_added + filtered_count
            on_message_history_processor_end(
                agent_name=self.name,
                session_id=getattr(self, "session_id", None),
                message_history=list(final_history),  # Copy to avoid mutation issues
                messages_added=messages_added,
                messages_filtered=messages_filtered,
            )

        return final_history

    def _spawn_ctrl_x_key_listener(
        self,
        stop_event: threading.Event,
        on_escape: Callable[[], None],
        on_cancel_agent: Callable[[], None] | None = None,
    ) -> threading.Thread | None:
        """Start a keyboard listener thread for CLI sessions.

        Listens for Ctrl+X (shell command cancel) and optionally the configured
        cancel_agent_key (when not using SIGINT/Ctrl+C).

        Args:
            stop_event: Event to signal the listener to stop.
            on_escape: Callback for Ctrl+X (shell command cancel).
            on_cancel_agent: Optional callback for cancel_agent_key (only used
                when cancel_agent_uses_signal() returns False).
        """
        try:
            import sys
        except ImportError:
            return None

        stdin = getattr(sys, "stdin", None)
        if stdin is None or not hasattr(stdin, "isatty"):
            return None
        try:
            if not stdin.isatty():
                return None
        except Exception:
            logger.debug("Failed in key listener setup", exc_info=True)
            return None

        def listener() -> None:
            try:
                if sys.platform.startswith("win"):
                    self._listen_for_ctrl_x_windows(
                        stop_event, on_escape, on_cancel_agent
                    )
                else:
                    self._listen_for_ctrl_x_posix(
                        stop_event, on_escape, on_cancel_agent
                    )
            except Exception:
                emit_warning(
                    "Key listener stopped unexpectedly; press Ctrl+C to cancel."
                )

        thread = threading.Thread(
            target=listener, name="code-puppy-key-listener", daemon=True
        )
        thread.start()
        return thread

    def _listen_for_ctrl_x_windows(
        self,
        stop_event: threading.Event,
        on_escape: Callable[[], None],
        on_cancel_agent: Callable[[], None] | None = None,
    ) -> None:
        import msvcrt

        # Get the cancel agent char code if we're using keyboard-based cancel
        cancel_agent_char: str | None = None
        if on_cancel_agent is not None and not cancel_agent_uses_signal():
            cancel_agent_char = get_cancel_agent_char_code()

        while not stop_event.is_set():
            try:
                if msvcrt.kbhit():
                    key = msvcrt.getwch()
                    if key == "\x18":  # Ctrl+X
                        try:
                            on_escape()
                        except Exception:
                            emit_warning(
                                "Ctrl+X handler raised unexpectedly; Ctrl+C still works."
                            )
                    elif (
                        cancel_agent_char
                        and on_cancel_agent
                        and key == cancel_agent_char
                    ):
                        try:
                            on_cancel_agent()
                        except Exception:
                            emit_warning("Cancel agent handler raised unexpectedly.")
            except Exception:
                emit_warning(
                    "Windows key listener error; Ctrl+C is still available for cancel."
                )
                return
            time.sleep(0.05)

    def _listen_for_ctrl_x_posix(
        self,
        stop_event: threading.Event,
        on_escape: Callable[[], None],
        on_cancel_agent: Callable[[], None] | None = None,
    ) -> None:
        import select
        import sys
        import termios
        import tty

        # Get the cancel agent char code if we're using keyboard-based cancel
        cancel_agent_char: str | None = None
        if on_cancel_agent is not None and not cancel_agent_uses_signal():
            cancel_agent_char = get_cancel_agent_char_code()

        stdin = sys.stdin
        try:
            fd = stdin.fileno()
        except AttributeError, ValueError, OSError:
            return
        try:
            original_attrs = termios.tcgetattr(fd)
        except Exception:
            logger.debug("Unix key listener setup failed", exc_info=True)
            return

        try:
            tty.setcbreak(fd)
            while not stop_event.is_set():
                try:
                    read_ready, _, _ = select.select([stdin], [], [], 0.05)
                except Exception:
                    logger.debug("Key listener read failed", exc_info=True)
                    break
                if not read_ready:
                    continue
                data = stdin.read(1)
                if not data:
                    break
                if data == "\x18":  # Ctrl+X
                    try:
                        on_escape()
                    except Exception:
                        emit_warning(
                            "Ctrl+X handler raised unexpectedly; Ctrl+C still works."
                        )
                elif (
                    cancel_agent_char and on_cancel_agent and data == cancel_agent_char
                ):
                    try:
                        on_cancel_agent()
                    except Exception:
                        emit_warning("Cancel agent handler raised unexpectedly.")
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, original_attrs)

    async def run_with_mcp(
        self,
        prompt: str,
        *,
        attachments: Sequence[BinaryContent | None] = None,
        link_attachments: Sequence[ImageUrl | DocumentUrl | None] = None,
        output_type: type[Any | None] = None,
        **kwargs,
    ) -> Any:
        """Run the agent with MCP servers, attachments, and full cancellation support.

        Args:
            prompt: Primary user prompt text (may be empty when attachments present).
            attachments: Local binary payloads (e.g., dragged images) to include.
            link_attachments: Remote assets (image/document URLs) to include.
            output_type: Optional Pydantic model or type for structured output.
                When provided, creates a temporary agent configured to return
                this type instead of the default string output.
            **kwargs: Additional arguments forwarded to `pydantic_ai.Agent.run`.

        Returns:
            The agent's response (typed according to output_type if specified).

        Raises:
            asyncio.CancelledError: When execution is cancelled by user.
        """
        # Sanitize prompt to remove invalid Unicode surrogates that can cause
        # encoding errors (especially common on Windows with copy-paste)
        if prompt:
            try:
                prompt = prompt.encode("utf-8", errors="surrogatepass").decode(
                    "utf-8", errors="replace"
                )
            except UnicodeEncodeError, UnicodeDecodeError:
                # Fallback: filter out surrogate characters directly
                prompt = "".join(
                    char if ord(char) < 0xD800 or ord(char) > 0xDFFF else "\ufffd"
                    for char in prompt
                )

        group_id = str(uuid.uuid4())
        # Avoid double-loading: reuse existing agent if already built
        pydantic_agent_instance = (
            self._state.code_generation_agent or self.reload_code_generation_agent()
        )

        # Warm MCP tool cache before first run so turn-1 context overhead is accurate.
        # _update_mcp_tool_cache is a no-op when cache is already populated or no
        # MCP servers are registered, so it is safe to call on every entry.
        if not self._state.mcp_tool_definitions_cache and self._state.mcp_servers:
            try:
                await self._update_mcp_tool_cache()
            except Exception:
                logger.debug(
                    "MCP server not connectable, cache stays empty", exc_info=True
                )

        # If a custom output_type is specified, create a temporary agent with that type
        if output_type is not None:
            pydantic_agent_instance = self._create_agent_with_output_type(output_type)

        # Handle model-specific prompt transformations via prepare_prompt_for_model()
        # This uses the get_model_system_prompt hook, so plugins can register their own handlers
        from code_puppy.model_utils import prepare_prompt_for_model

        # Only prepend system prompt on first message (empty history)
        should_prepend = len(self.get_message_history()) == 0
        if should_prepend:
            system_prompt = self.get_full_system_prompt()
            puppy_rules = self.load_puppy_rules()
            if puppy_rules:
                system_prompt += f"\n{puppy_rules}"

            prepared = prepare_prompt_for_model(
                model_name=self.get_model_name(),
                system_prompt=system_prompt,
                user_prompt=prompt,
                prepend_system_to_user=True,
            )
            prompt = prepared.user_prompt

        # Build combined prompt payload when attachments are provided.
        attachment_parts: list[Any] = []
        if attachments:
            attachment_parts.extend(list(attachments))
        if link_attachments:
            attachment_parts.extend(list(link_attachments))

        if attachment_parts:
            prompt_payload: str | list[Any] = []
            if prompt:
                prompt_payload.append(prompt)
            prompt_payload.extend(attachment_parts)
        else:
            prompt_payload = prompt

        async def run_agent_task():
            try:
                self.set_message_history(
                    self.prune_interrupted_tool_calls(self.get_message_history())
                )

                # DELAYED COMPACTION: Check if we should attempt delayed compaction
                if self.should_attempt_delayed_compaction():
                    emit_info(
                        "🔄 Attempting delayed compaction (tool calls completed)",
                        message_group="token_context_status",
                    )
                    current_messages = self.get_message_history()
                    compacted_messages, _ = self.compact_messages(current_messages)
                    if compacted_messages != current_messages:
                        self.set_message_history(compacted_messages)
                        emit_info(
                            "✅ Delayed compaction completed successfully",
                            message_group="token_context_status",
                        )

                cfg = get_puppy_config()
                usage_limits = UsageLimits(request_limit=cfg.message_limit)

                # Build context managers based on configuration, then run once.
                @contextlib.contextmanager
                def _mcp_injection():
                    """Temporarily inject MCP servers into DBOS agent toolsets."""
                    if get_use_dbos() and self._state.mcp_servers:
                        original = pydantic_agent_instance._toolsets
                        pydantic_agent_instance._toolsets = (
                            original + self._state.mcp_servers
                        )
                        try:
                            yield
                        finally:
                            pydantic_agent_instance._toolsets = original
                    else:
                        yield

                # Set the workflow ID for DBOS context so DBOS and Code Puppy ID match
                workflow_ctx = (
                    SetWorkflowID(group_id)
                    if get_use_dbos()
                    else contextlib.nullcontext()
                )

                with _mcp_injection(), workflow_ctx:
                    # Pre-send context budget check
                    self._check_context_budget_before_send(prompt_payload)

                    # Check hard token budgets
                    try:
                        _pre_est = (
                            self.estimate_context_overhead_tokens()
                            + self._estimate_batch_tokens(self.get_message_history())
                        )
                        self._check_token_budgets(_pre_est)
                    except RuntimeError:
                        raise
                    except Exception:
                        logger.debug(
                            "Token budget check failed, continuing", exc_info=True
                        )

                    # Pre-compute estimated tokens for ledger reporting
                    try:
                        _est_input = (
                            self.estimate_context_overhead_tokens()
                            + self._estimate_batch_tokens(self.get_message_history())
                        )
                        if isinstance(prompt_payload, str):
                            _est_input += self.estimate_token_count(prompt_payload)
                        elif isinstance(prompt_payload, list):
                            for _item in prompt_payload:
                                if isinstance(_item, str):
                                    _est_input += self.estimate_token_count(_item)
                                elif hasattr(_item, "content") and isinstance(
                                    _item.content, str
                                ):
                                    _est_input += self.estimate_token_count(
                                        _item.content
                                    )
                    except Exception:
                        _est_input = 0

                    # Code Puppy retry loop: wraps pydantic-ai's run() to track
                    # retry costs in the token ledger. Pydantic-ai's internal
                    # retries=3 handles output validation retries, but those are
                    # invisible to us. This outer loop catches
                    # UnexpectedModelBehavior (when pydantic-ai exhausts its
                    # retries) and records each failed attempt with retry_number.
                    _max_outer_retries = 3
                    _last_error: Exception | None = None

                    for _retry_number in range(_max_outer_retries + 1):
                        try:
                            result_ = await pydantic_agent_instance.run(
                                prompt_payload,
                                message_history=self.get_message_history(),
                                usage_limits=usage_limits,
                                event_stream_handler=event_stream_handler,
                                **kwargs,
                            )
                            # Record successful token usage in the session ledger
                            try:
                                usage = result_.usage()
                                details = getattr(usage, "details", None)
                                cache_read = None
                                if details and isinstance(details, dict):
                                    cache_read = details.get("cached_content_tokens")
                                self._state.get_token_ledger().record(
                                    TokenAttempt(
                                        model=self.get_model_name(),
                                        estimated_input_tokens=_est_input,
                                        estimated_output_tokens=getattr(
                                            usage, "output_tokens", None
                                        )
                                        or 0,
                                        provider_input_tokens=getattr(
                                            usage, "input_tokens", None
                                        ),
                                        provider_output_tokens=getattr(
                                            usage, "output_tokens", None
                                        ),
                                        cache_read_tokens=getattr(
                                            usage, "cache_read_tokens", None
                                        )
                                        or cache_read,
                                        cache_write_tokens=getattr(
                                            usage, "cache_write_tokens", None
                                        ),
                                        success=True,
                                        retry_number=_retry_number,
                                        agent_name=self.name,
                                    )
                                )
                            except Exception:
                                logger.debug(
                                    "Failed to record token usage", exc_info=True
                                )
                            return result_
                        except UnexpectedModelBehavior as _umb:
                            _last_error = _umb
                            _error_msg = str(_umb)[:200]
                            # Record the failed attempt
                            try:
                                self._state.get_token_ledger().record(
                                    TokenAttempt(
                                        model=self.get_model_name(),
                                        estimated_input_tokens=_est_input,
                                        estimated_output_tokens=0,
                                        success=False,
                                        error=_error_msg,
                                        retry_number=_retry_number,
                                        agent_name=self.name,
                                    )
                                )
                            except Exception:
                                pass

                            if _retry_number < _max_outer_retries:
                                logger.warning(
                                    "Retry %d/%d after UnexpectedModelBehavior: %s",
                                    _retry_number + 1,
                                    _max_outer_retries,
                                    _error_msg,
                                )
                                # Brief backoff before retrying
                                await asyncio.sleep(1.0 * (_retry_number + 1))
                                continue
                            # Exhausted outer retries - let it propagate to the
                            # existing error handling below
                            raise _last_error
            except* UsageLimitExceeded as ule:
                emit_info(f"Usage limit exceeded: {str(ule)}", group_id=group_id)
                emit_info(
                    "The agent has reached its usage limit. You can ask it to continue by saying 'please continue' or similar.",
                    group_id=group_id,
                )
            except* mcp.shared.exceptions.McpError as mcp_error:
                emit_info(f"MCP server error: {str(mcp_error)}", group_id=group_id)
                emit_info(f"{str(mcp_error)}", group_id=group_id)
                emit_info(
                    "Try disabling any malfunctioning MCP servers", group_id=group_id
                )
            except* asyncio.exceptions.CancelledError:
                emit_info("Cancelled")
                if get_use_dbos():
                    await DBOS.cancel_workflow_async(group_id)
            except* InterruptedError as ie:
                emit_info(f"Interrupted: {str(ie)}")
                if get_use_dbos():
                    await DBOS.cancel_workflow_async(group_id)
            except* Exception as other_error:
                # Filter out CancelledError and UsageLimitExceeded from the exception group - let it propagate
                remaining_exceptions = []

                def collect_non_cancelled_exceptions(exc):
                    if isinstance(exc, ExceptionGroup):
                        for sub_exc in exc.exceptions:
                            collect_non_cancelled_exceptions(sub_exc)
                    elif not isinstance(
                        exc, (asyncio.CancelledError, UsageLimitExceeded)
                    ):
                        remaining_exceptions.append(exc)
                        error_msg = str(exc)

                        # Detect context overflow and provide actionable guidance
                        if is_context_overflow(error_msg):
                            emit_info(
                                "⚠️ Context window overflow detected. "
                                "The conversation history is too large for the model.",
                                group_id=group_id,
                            )
                            emit_info(
                                "Try: /compact to manually compact history, "
                                "or start a new conversation with /reset",
                                group_id=group_id,
                            )
                            # Request compaction for the next turn
                            self._state.delayed_compaction_requested = True
                            logger.warning(
                                "Context overflow detected, requesting compaction: %s",
                                error_msg[:200],
                            )
                            # Record overflow in token ledger (best-effort)
                            try:
                                self._state.get_token_ledger().record(
                                    TokenAttempt(
                                        model=self.get_model_name(),
                                        estimated_input_tokens=_est_input,
                                        estimated_output_tokens=0,
                                        success=False,
                                        error=error_msg[:200],
                                        is_overflow=True,
                                        retry_number=0,
                                        agent_name=self.name,
                                    )
                                )
                            except Exception:
                                pass
                        else:
                            emit_info(
                                f"Unexpected error: {error_msg}",
                                group_id=group_id,
                            )
                            emit_info(f"{str(exc.args)}", group_id=group_id)

                        # Always log to file for debugging
                        log_error(
                            exc,
                            context=f"Agent run (group_id={group_id})",
                            include_traceback=True,
                        )

                collect_non_cancelled_exceptions(other_error)

                # Fire agent_exception callback for each non-cancelled exception
                for _exc in remaining_exceptions:
                    try:
                        await on_agent_exception(
                            _exc, agent_name=self.name, group_id=group_id
                        )
                    except Exception:
                        logger.debug("agent_exception callback failed", exc_info=True)

                # Re-raise remaining exceptions so they propagate and signal
                # actual failure. This prevents _run_success = True from being
                # set when real errors occurred.
                if remaining_exceptions:
                    if len(remaining_exceptions) == 1:
                        raise remaining_exceptions[0]
                    raise ExceptionGroup(
                        "Agent run failed with multiple exceptions",
                        remaining_exceptions,
                    )
            finally:
                self.set_message_history(
                    self.prune_interrupted_tool_calls(self.get_message_history())
                )

        # Create the task FIRST
        agent_task = asyncio.create_task(run_agent_task())

        # Fire agent_run_start hook - plugins can use this to start background tasks
        # (e.g., token refresh heartbeats for OAuth models)
        # Also creates a RunContext for hierarchical tracing
        _run_context = None
        _run_usage = None  # Will hold provider usage data for trace reconciliation
        try:
            _start_results, _run_context = await on_agent_run_start(
                agent_name=self.name,
                model_name=self.get_model_name(),
                session_id=group_id,
                tags=["agent_run"],
                metadata={"agent_version": getattr(self, "version", None)},
            )
        except Exception:
            logger.debug("agent_run_start hook failed", exc_info=True)
            _run_context = None

        loop = asyncio.get_running_loop()

        def schedule_agent_cancel() -> None:
            from code_puppy.tools.command_runner import _RUNNING_PROCESSES

            if len(_RUNNING_PROCESSES):
                emit_warning(
                    "Refusing to cancel Agent while a shell command is currently running - press Ctrl+X to cancel the shell command."
                )
                return
            if agent_task.done():
                return

            # Cancel all active subagent tasks
            if _active_subagent_tasks:
                emit_warning(
                    f"Cancelling {len(_active_subagent_tasks)} active subagent task(s)..."
                )
                for task in list(
                    _active_subagent_tasks
                ):  # Create a copy since we'll be modifying the set
                    if not task.done():
                        loop.call_soon_threadsafe(task.cancel)
            loop.call_soon_threadsafe(agent_task.cancel)

        def keyboard_interrupt_handler(_sig, _frame):
            # If we're awaiting user input (e.g., file permission prompt),
            # don't cancel the agent - let the input() call handle the interrupt naturally
            if is_awaiting_user_input():
                # Don't do anything here - let the input() call raise KeyboardInterrupt naturally
                return

            schedule_agent_cancel()

        def graceful_sigint_handler(_sig, _frame):
            # When using keyboard-based cancel, SIGINT should be a no-op
            # (just show a hint to user about the configured cancel key)
            # Also reset terminal to prevent bricking on Windows+uvx
            from code_puppy.keymap import get_cancel_agent_display_name
            from code_puppy.terminal_utils import reset_windows_terminal_full

            # Reset terminal state first to prevent bricking
            reset_windows_terminal_full()

            cancel_key = get_cancel_agent_display_name()
            emit_info(f"Use {cancel_key} to cancel the agent task.")

        original_handler = None
        key_listener_stop_event = None
        _key_listener_thread = None

        try:
            if cancel_agent_uses_signal():
                # Use SIGINT-based cancellation (default Ctrl+C behavior)
                original_handler = signal.signal(
                    signal.SIGINT, keyboard_interrupt_handler
                )
            else:
                # Use keyboard listener for agent cancellation
                # Set a graceful SIGINT handler that shows a hint
                original_handler = signal.signal(signal.SIGINT, graceful_sigint_handler)
                # Spawn keyboard listener with the cancel agent callback
                key_listener_stop_event = threading.Event()
                _key_listener_thread = self._spawn_ctrl_x_key_listener(
                    key_listener_stop_event,
                    on_escape=lambda: None,  # Ctrl+X handled by command_runner
                    on_cancel_agent=schedule_agent_cancel,
                )

            # Wait for the task to complete or be cancelled
            result = await agent_task

            # Extract provider usage for trace reconciliation
            try:
                if result is not None and hasattr(result, "usage"):
                    usage = result.usage()
                    if usage:
                        _run_usage = {
                            "input_tokens": getattr(usage, "input_tokens", None),
                            "output_tokens": getattr(usage, "output_tokens", None),
                            "reasoning_tokens": getattr(
                                usage, "reasoning_tokens", None
                            ),
                            "cache_read_tokens": getattr(
                                usage, "cache_read_tokens", None
                            )
                            or getattr(usage, "cache_read_input_tokens", None),
                            "cache_write_tokens": getattr(
                                usage, "cache_write_tokens", None
                            )
                            or getattr(usage, "cache_creation_input_tokens", None),
                        }
            except Exception:
                logger.debug("Failed to extract usage for trace", exc_info=True)

            # Update MCP tool cache after successful run for accurate token estimation
            if self._state.mcp_servers:
                try:
                    await self._update_mcp_tool_cache()
                except Exception:
                    logger.debug("Cache update failed", exc_info=True)

            # Extract response text for the callback
            _run_response_text = ""
            if result is not None:
                if hasattr(result, "data"):
                    _run_response_text = str(result.data) if result.data else ""
                elif hasattr(result, "output"):
                    _run_response_text = str(result.output) if result.output else ""
                else:
                    _run_response_text = str(result)

            _run_success = True
            _run_error = None
            return result
        except asyncio.CancelledError:
            _run_success = False
            _run_error = None  # Cancellation is not an error
            _run_response_text = ""
            agent_task.cancel()
        except KeyboardInterrupt:
            _run_success = False
            _run_error = None  # User interrupt is not an error
            _run_response_text = ""
            if not agent_task.done():
                agent_task.cancel()
        except Exception as e:
            _run_success = False
            _run_error = e
            _run_response_text = ""
            # Fire agent_exception callback
            try:
                await on_agent_exception(e, agent_name=self.name, group_id=group_id)
            except Exception:
                logger.debug("Error path callback failed", exc_info=True)
            raise
        finally:
            # Fire agent_run_end hook - plugins can use this for:
            # - Stopping background tasks (token refresh heartbeats)
            # - Workflow orchestration (Ralph's autonomous loop)
            # - Logging/analytics
            # - Completing RunContext tracing
            try:
                await on_agent_run_end(
                    agent_name=self.name,
                    model_name=self.get_model_name(),
                    session_id=group_id,
                    success=_run_success,
                    error=_run_error,
                    response_text=_run_response_text,
                    metadata={"model": self.get_model_name(), "usage": _run_usage},
                    run_context=_run_context,
                )
            except Exception:
                logger.debug("Cleanup hook failed", exc_info=True)

            # Stop keyboard listener if it was started
            if key_listener_stop_event is not None:
                key_listener_stop_event.set()
            # Restore original signal handler
            if (
                original_handler is not None
            ):  # Explicit None check - SIG_DFL can be 0/falsy!
                signal.signal(signal.SIGINT, original_handler)
