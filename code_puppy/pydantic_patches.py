"""Monkey patches for pydantic-ai.

This module contains all monkey patches needed to customize pydantic-ai behavior.
These patches MUST be applied before any other pydantic-ai imports to work correctly.

Usage:
    from code_puppy.pydantic_patches import apply_all_patches
    apply_all_patches()
"""

import importlib.metadata
import logging
import time
from typing import Any

logger = logging.getLogger(__name__)


def _get_code_puppy_version() -> str:
    """Get the current code-puppy version."""
    try:
        return importlib.metadata.version("code-puppy")
    except Exception:
        return "0.0.0-dev"


def patch_user_agent() -> None:
    """Patch pydantic-ai's User-Agent to use Code-Puppy's version.

    pydantic-ai sets its own User-Agent ('pydantic-ai/x.x.x') via a @cache-decorated
    function. We replace it with a dynamic function that returns:
    - 'KimiCLI/0.63' for Kimi models
    - 'Code-Puppy/{version}' for all other models

    This MUST be called before any pydantic-ai models are created.
    """
    try:
        import pydantic_ai.models as pydantic_models

        version = _get_code_puppy_version()

        # Clear cache if already called
        if hasattr(pydantic_models.get_user_agent, "cache_clear"):
            pydantic_models.get_user_agent.cache_clear()

        def _get_dynamic_user_agent() -> str:
            """Return User-Agent based on current model selection."""
            try:
                from code_puppy.config import get_global_model_name

                model_name = get_global_model_name()
                if model_name and "kimi" in model_name.lower():
                    return "KimiCLI/0.63"
            except Exception:
                pass
            return f"Code-Puppy/{version}"

        pydantic_models.get_user_agent = _get_dynamic_user_agent
    except Exception:
        pass  # Don't crash on patch failure


def patch_message_history_cleaning() -> None:
    """Disable overly strict message history cleaning in pydantic-ai."""
    try:
        from pydantic_ai import _agent_graph

        _agent_graph._clean_message_history = lambda messages: messages
    except Exception:
        pass


def patch_process_message_history() -> None:
    """Patch _process_message_history to skip strict ModelRequest validation.

    Pydantic AI added a validation that history must end with ModelRequest,
    but this breaks valid conversation flows. We patch it to skip that validation.
    """
    try:
        from pydantic_ai import _agent_graph

        async def _patched_process_message_history(messages, processors, run_context):
            """Patched version that doesn't enforce ModelRequest at end."""
            from pydantic_ai._agent_graph import (
                _HistoryProcessorAsync,
                _HistoryProcessorSync,
                _HistoryProcessorSyncWithCtx,
                cast,
                exceptions,
                is_async_callable,
                is_takes_ctx,
                run_in_executor,
            )

            for processor in processors:
                takes_ctx = is_takes_ctx(processor)

                if is_async_callable(processor):
                    if takes_ctx:
                        messages = await processor(run_context, messages)
                    else:
                        async_processor = cast(_HistoryProcessorAsync, processor)
                        messages = await async_processor(messages)
                else:
                    if takes_ctx:
                        sync_processor_with_ctx = cast(
                            _HistoryProcessorSyncWithCtx, processor
                        )
                        messages = await run_in_executor(
                            sync_processor_with_ctx, run_context, messages
                        )
                    else:
                        sync_processor = cast(_HistoryProcessorSync, processor)
                        messages = await run_in_executor(sync_processor, messages)

            if len(messages) == 0:
                raise exceptions.UserError("Processed history cannot be empty.")

            # NOTE: We intentionally skip the "must end with ModelRequest" validation
            # that was added in newer Pydantic AI versions.

            return messages

        _agent_graph._process_message_history = _patched_process_message_history
    except Exception:
        pass


def patch_tool_call_json_repair() -> None:
    """Patch pydantic-ai's _call_tool to auto-repair malformed JSON arguments.

    LLMs sometimes produce slightly broken JSON in tool calls (trailing commas,
    missing quotes, etc.). This patch intercepts tool calls and runs json_repair
    on the arguments before validation, preventing unnecessary retries.
    """
    try:
        import json_repair
        from pydantic_ai._tool_manager import ToolManager

        # Store the original method
        _original_call_tool = ToolManager._call_tool

        async def _patched_call_tool(
            self,
            call,
            *,
            allow_partial: bool,
            wrap_validation_errors: bool,
            approved: bool,
            metadata: Any = None,
        ):
            """Patched _call_tool that repairs malformed JSON before validation."""
            # Only attempt repair if args is a string (JSON)
            if isinstance(call.args, str) and call.args:
                try:
                    repaired = json_repair.repair_json(call.args)
                    if repaired != call.args:
                        # Update the call args with repaired JSON
                        call.args = repaired
                except Exception:
                    pass  # If repair fails, let original validation handle it

            # Call the original method
            return await _original_call_tool(
                self,
                call,
                allow_partial=allow_partial,
                wrap_validation_errors=wrap_validation_errors,
                approved=approved,
                metadata=metadata,
            )

        # Apply the patch
        ToolManager._call_tool = _patched_call_tool

    except ImportError:
        pass  # json_repair or pydantic_ai not available
    except Exception:
        pass  # Don't crash on patch failure


def patch_tool_call_callbacks() -> None:
    """Patch pydantic-ai tool handling to support callbacks and Claude Code tool names.

    Claude Code OAuth prefixes tool names with ``cp_`` on the wire.  pydantic-ai
    classifies tool calls *before* ``_call_tool`` runs, so unprefixing only in
    ``_call_tool`` is too late: prefixed tools get marked as ``unknown`` and can
    burn through result retries, eventually raising ``UnexpectedModelBehavior``.

    This patch normalizes Claude Code tool names early (during lookup/dispatch)
    and wraps ``_call_tool`` so every tool invocation also triggers the
    ``pre_tool_call`` and ``post_tool_call`` callbacks defined in
    ``code_puppy.callbacks``.
    """
    try:
        from pydantic_ai._tool_manager import ToolManager

        _original_call_tool = ToolManager._call_tool
        _original_get_tool_def = ToolManager.get_tool_def
        _original_handle_call = ToolManager.handle_call

        # Tool name prefix used by Claude Code OAuth - tools are prefixed on
        # outgoing requests, so we need to unprefix them when they come back.
        TOOL_PREFIX = "cp_"

        def _normalize_tool_name(name: Any) -> Any:
            """Strip the ``cp_`` prefix if present."""
            if isinstance(name, str) and name.startswith(TOOL_PREFIX):
                return name[len(TOOL_PREFIX) :]
            return name

        def _normalize_call_tool_name(call: Any) -> tuple[Any, Any]:
            """Normalize the tool_name on a call object in-place."""
            tool_name = getattr(call, "tool_name", None)
            normalized_name = _normalize_tool_name(tool_name)
            if normalized_name != tool_name:
                try:
                    call.tool_name = normalized_name
                except AttributeError, TypeError:
                    pass
            return normalized_name, call

        # -- Early normalization patches -----------------------------------------
        # These run *before* pydantic-ai classifies the tool as function/output/
        # unknown, so prefixed names resolve correctly.

        def _patched_get_tool_def(self, name: str):
            return _original_get_tool_def(self, _normalize_tool_name(name))

        async def _patched_handle_call(
            self,
            call,
            allow_partial: bool = False,
            wrap_validation_errors: bool = True,
            *,
            approved: bool = False,
            metadata: Any = None,
        ):
            _normalize_call_tool_name(call)
            return await _original_handle_call(
                self,
                call,
                allow_partial=allow_partial,
                wrap_validation_errors=wrap_validation_errors,
                approved=approved,
                metadata=metadata,
            )

        # -- _call_tool wrapper with callbacks -----------------------------------

        async def _patched_call_tool(
            self,
            call,
            *,
            allow_partial: bool,
            wrap_validation_errors: bool,
            approved: bool,
            metadata: Any = None,
        ):
            tool_name, call = _normalize_call_tool_name(call)

            # Normalise args to a dict for the callback contract
            tool_args: dict = {}
            if isinstance(call.args, dict):
                tool_args = call.args
            elif isinstance(call.args, str):
                try:
                    import json

                    tool_args = json.loads(call.args)
                except Exception:
                    tool_args = {"raw": call.args}

            # --- pre_tool_call (with blocking support) ---
            # Returns a string tool-result on block so pydantic-ai sees a clean
            # "BLOCKED: ..." message and the agent can react gracefully, without
            # triggering UnexpectedModelBehavior crashes.
            try:
                from code_puppy import callbacks
                from code_puppy.messaging import emit_warning
                from code_puppy.run_context import (
                    get_current_run_context,
                )

                # Get current run context for tracing
                current_ctx = get_current_run_context()
                callback_results = await callbacks.on_pre_tool_call(
                    tool_name, tool_args, current_ctx
                )

                for callback_result in callback_results:
                    # Handle Deny objects from permission_decision (fail-closed semantics)
                    from code_puppy.permission_decision import Deny

                    if isinstance(callback_result, Deny):
                        raw_reason = getattr(callback_result, "reason", "") or ""
                        user_feedback = (
                            getattr(callback_result, "user_feedback", "") or ""
                        )
                        if "[BLOCKED]" in raw_reason:
                            clean_reason = raw_reason[
                                raw_reason.index("[BLOCKED]") :
                            ].strip()
                        elif user_feedback:
                            clean_reason = user_feedback
                        else:
                            clean_reason = "Tool execution blocked by security check"
                        block_msg = f"🚫 Hook blocked this tool call: {clean_reason}"
                        emit_warning(block_msg)
                        return f"ERROR: {block_msg}\n\nThe hook policy prevented this tool from running. Please inform the user and do not retry this specific command."
                    # Handle legacy dict format
                    if (
                        callback_result
                        and isinstance(callback_result, dict)
                        and callback_result.get("blocked")
                    ):
                        raw_reason = (
                            callback_result.get("error_message")
                            or callback_result.get("reason")
                            or ""
                        )
                        if "[BLOCKED]" in raw_reason:
                            clean_reason = raw_reason[
                                raw_reason.index("[BLOCKED]") :
                            ].strip()
                        else:
                            clean_reason = (
                                raw_reason.strip() or "Tool execution blocked by hook"
                            )
                        block_msg = f"🚫 Hook blocked this tool call: {clean_reason}"
                        emit_warning(block_msg)
                        return f"ERROR: {block_msg}\n\nThe hook policy prevented this tool from running. Please inform the user and do not retry this specific command."
            except Exception as e:
                # SECURITY: Changed from pass to fail-closed behavior
                # If the callback system itself fails, we should block the tool
                # to prevent potential security bypass. If the callback fails,
                # there's likely a serious problem that shouldn't be ignored.
                logger.error(
                    "Pre-tool-call callback system error: %s", e, exc_info=True
                )
                emit_warning(
                    "🚫 Security callback system error; blocking tool execution"
                )
                return "ERROR: Security callback system error. Tool execution blocked to maintain safety."

            start = time.perf_counter()
            error: Exception | None = None
            result = None
            try:
                result = await _original_call_tool(
                    self,
                    call,
                    allow_partial=allow_partial,
                    wrap_validation_errors=wrap_validation_errors,
                    approved=approved,
                    metadata=metadata,
                )
                return result
            except Exception as exc:
                error = exc
                raise
            finally:
                duration_ms = (time.perf_counter() - start) * 1000
                final_result = result if error is None else {"error": str(error)}
                try:
                    from code_puppy import callbacks
                    from code_puppy.run_context import get_current_run_context

                    # Get current run context for tracing
                    current_ctx = get_current_run_context()
                    await callbacks.on_post_tool_call(
                        tool_name, tool_args, final_result, duration_ms, current_ctx
                    )
                except Exception:
                    pass  # never block tool execution

        ToolManager.get_tool_def = _patched_get_tool_def
        ToolManager.handle_call = _patched_handle_call
        ToolManager._call_tool = _patched_call_tool

    except ImportError:
        pass
    except Exception:
        pass


def patch_anthropic_tool_id_sanitization() -> None:
    """Patch AnthropicModel to sanitize tool_call_id values before requests.

    When using mixed provider setups (e.g. ChatGPT history sent to Claude),
    OpenAI tool_call_id values can contain characters outside the Anthropic-allowed
    pattern ^[a-zA-Z0-9_-]+$ (dots, slashes, colons, etc.). Anthropic rejects these
    with 400 errors.

    This patch wraps request/request_stream to normalize tool_call_id values on
    all ToolCallPart and ToolReturnPart instances before they're serialized.

    IMPORTANT: We do NOT mutate the caller's message history in place. Instead,
    we create shallow copies of messages and use dataclasses.replace() to create
    sanitized part copies. This preserves the async context manager contract
    of request_stream and doesn't corrupt shared history.

    This function is idempotent - calling it multiple times is safe.
    """
    try:
        import dataclasses
        from contextlib import asynccontextmanager

        from pydantic_ai.messages import RetryPromptPart, ToolCallPart, ToolReturnPart
        from pydantic_ai.models.anthropic import AnthropicModel

        # Import our sanitizer (fails gracefully if not available)
        try:
            from code_puppy.claude_cache_client import sanitize_tool_id
        except Exception:
            logger.debug("sanitize_tool_id not available, skipping patch")
            return

        # Types that have tool_call_id we need to sanitize
        _PARTS_WITH_TOOL_CALL_ID = (ToolCallPart, ToolReturnPart, RetryPromptPart)

        def _sanitize_message_history(messages: list) -> list:
            """Build a shallow-copied message history with sanitized tool_call_ids.

            Returns a new list of messages; the original is untouched.
            """
            if not messages or not isinstance(messages, list):
                return messages

            sanitized_messages = []
            for message in messages:
                if not message:
                    sanitized_messages.append(message)
                    continue

                # Get parts from ModelRequest or ModelResponse
                parts = getattr(message, "parts", None)
                if not parts or not isinstance(parts, (list, tuple)):
                    sanitized_messages.append(message)
                    continue

                # Build new parts list with sanitized copies where needed
                new_parts = []
                parts_changed = False
                for part in parts:
                    if not part:
                        new_parts.append(part)
                        continue

                    if isinstance(part, _PARTS_WITH_TOOL_CALL_ID):
                        raw_id = part.tool_call_id
                        if isinstance(raw_id, str):
                            new_id = sanitize_tool_id(raw_id)
                            if new_id != raw_id:
                                # Create a new part with the sanitized id
                                # ToolCallPart/ToolReturnPart/RetryPromptPart are dataclasses
                                try:
                                    new_part = dataclasses.replace(
                                        part, tool_call_id=new_id
                                    )
                                    new_parts.append(new_part)
                                    parts_changed = True
                                    continue
                                except (
                                    TypeError,
                                    ValueError,
                                    dataclasses.FrozenInstanceError,
                                ):
                                    # Fallback: try direct attribute assignment (mutable dataclass)
                                    try:
                                        part.tool_call_id = new_id
                                        new_parts.append(part)
                                        parts_changed = True
                                        continue
                                    except AttributeError, TypeError:
                                        # Last resort: keep original
                                        pass
                    # If we get here, part was not replaced
                    new_parts.append(part)

                if parts_changed:
                    # Build a shallow copy of the message with new parts
                    # ModelRequest and ModelResponse are dataclasses
                    try:
                        new_message = dataclasses.replace(message, parts=new_parts)
                        sanitized_messages.append(new_message)
                    except TypeError, ValueError, dataclasses.FrozenInstanceError:
                        # Fallback: try to set parts directly
                        try:
                            message.parts = new_parts
                            sanitized_messages.append(message)
                        except AttributeError, TypeError:
                            sanitized_messages.append(message)
                else:
                    sanitized_messages.append(message)

            return sanitized_messages

        # Get the current method - this could be the original or already patched
        # If already patched, we re-wrap (outer wrapper calls inner wrapper which calls original)
        _original_request = AnthropicModel.request

        async def _patched_request(
            self, messages, model_settings, model_request_parameters
        ):
            try:
                sanitized_messages = _sanitize_message_history(messages)
            except Exception as exc:
                # Sanitization must NEVER crash the request path
                logger.debug(
                    "Error during tool id sanitization (pydantic-ai request): %s", exc
                )
                sanitized_messages = messages
            return await _original_request(
                self, sanitized_messages, model_settings, model_request_parameters
            )

        # Patch request_stream method - MUST preserve async context manager contract
        _original_request_stream = AnthropicModel.request_stream

        @asynccontextmanager
        async def _patched_request_stream(
            self, messages, model_settings, model_request_parameters, run_context=None
        ):
            try:
                sanitized_messages = _sanitize_message_history(messages)
            except Exception as exc:
                # Sanitization must NEVER crash the request path
                logger.debug(
                    "Error during tool id sanitization (pydantic-ai stream): %s", exc
                )
                sanitized_messages = messages

            # The original is an @asynccontextmanager, so we must use 'async with'
            async with _original_request_stream(
                self,
                sanitized_messages,
                model_settings,
                model_request_parameters,
                run_context,
            ) as response:
                yield response

        AnthropicModel.request = _patched_request
        AnthropicModel.request_stream = _patched_request_stream

    except ImportError:
        pass  # pydantic-ai or anthropic model not available
    except Exception as exc:
        logger.debug("Failed to apply Anthropic tool id sanitization patch: %s", exc)


def apply_all_patches() -> None:
    """Apply all pydantic-ai monkey patches.

    Call this at the very top of main.py, before any other imports.
    """
    patch_user_agent()
    patch_message_history_cleaning()
    patch_process_message_history()
    patch_tool_call_json_repair()
    patch_tool_call_callbacks()
    patch_anthropic_tool_id_sanitization()
