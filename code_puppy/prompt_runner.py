"""Prompt running helpers for Code Puppy.

Provides run_prompt_with_attachments() and execute_single_prompt() utilities
used by both the interactive REPL loop and single-shot prompt execution.
"""

import asyncio
import re

from code_puppy.agents import get_current_agent
from code_puppy.command_line.attachments import parse_prompt_attachments
from code_puppy.command_line.clipboard import get_clipboard_manager
from code_puppy.messaging import emit_info


async def run_prompt_with_attachments(
    agent, raw_prompt: str, *, spinner_console=None, use_spinner: bool = True
):
    """Run the agent after parsing CLI attachments for image/document support.

    Returns:
        tuple: (result, task) where result is the agent response and task is the asyncio task
    """
    from code_puppy.messaging import emit_system_message, emit_warning

    processed_prompt = parse_prompt_attachments(raw_prompt)

    for warning in processed_prompt.warnings:
        emit_warning(warning)

    # Get clipboard images and merge with file attachments
    clipboard_manager = get_clipboard_manager()
    clipboard_images = clipboard_manager.get_pending_images()

    # Clear pending clipboard images after retrieval
    clipboard_manager.clear_pending()

    # Build summary of all attachments
    summary_parts = []
    if processed_prompt.attachments:
        summary_parts.append(f"files: {len(processed_prompt.attachments)}")
    if clipboard_images:
        summary_parts.append(f"clipboard images: {len(clipboard_images)}")
    if processed_prompt.link_attachments:
        summary_parts.append(f"urls: {len(processed_prompt.link_attachments)}")
    if summary_parts:
        emit_system_message("Attachments detected -> " + ", ".join(summary_parts))

    # Clean up clipboard placeholders from the prompt text
    cleaned_prompt = processed_prompt.prompt
    if clipboard_images and cleaned_prompt:
        cleaned_prompt = re.sub(
            r"\[📋 clipboard image \d+\]\s*", "", cleaned_prompt
        ).strip()

    if not cleaned_prompt:
        emit_warning(
            "Prompt is empty after removing attachments; add instructions and retry."
        )
        return None, None

    # Combine file attachments with clipboard images
    attachments = [attachment.content for attachment in processed_prompt.attachments]
    attachments.extend(clipboard_images)  # Add clipboard images

    link_attachments = [link.url_part for link in processed_prompt.link_attachments]

    # IMPORTANT: Set the shared console for streaming output so it
    # uses the same console as the spinner. This keeps spinner pause/resume
    # coordination working for thinking-part and tool-call output. Text parts
    # are now streamed as plain escaped chunks (no Rich Live wrapper) to avoid
    # the cascading re-render bug that happened with long markdown content —
    #
    from code_puppy.agents.event_stream_handler import set_streaming_console

    set_streaming_console(spinner_console)

    # Create the agent task first so we can track and cancel it
    agent_task = asyncio.create_task(
        agent.run_with_mcp(
            cleaned_prompt,  # Use cleaned prompt (clipboard placeholders removed)
            attachments=attachments,
            link_attachments=link_attachments,
        )
    )

    if use_spinner and spinner_console is not None:
        from code_puppy.messaging.spinner import ConsoleSpinner

        with ConsoleSpinner(console=spinner_console):
            try:
                result = await agent_task
                return result, agent_task
            except asyncio.CancelledError:
                emit_info("Agent task cancelled")
                return None, agent_task
    else:
        try:
            result = await agent_task
            return result, agent_task
        except asyncio.CancelledError:
            emit_info("Agent task cancelled")
            return None, agent_task


async def execute_single_prompt(prompt: str, message_renderer) -> None:
    """Execute a single prompt and exit (for -p flag)."""
    # Shell pass-through: !<cmd> bypasses the agent even in -p mode
    from code_puppy.command_line.shell_passthrough import (
        execute_shell_passthrough,
        is_shell_passthrough,
    )

    if is_shell_passthrough(prompt):
        execute_shell_passthrough(prompt)
        return

    from code_puppy.messaging import emit_info

    emit_info(f"Executing prompt: {prompt}")

    try:
        # Get agent through runtime manager and use helper for attachments
        agent = get_current_agent()
        result, _agent_task = await run_prompt_with_attachments(
            agent, prompt, spinner_console=message_renderer.console
        )
        if result is None:
            return

        agent_response = result.output

        # Emit structured message for proper markdown rendering
        from code_puppy.agents.event_stream_handler import get_stream_state
        from code_puppy.messaging import get_message_bus
        from code_puppy.messaging.messages import AgentResponseMessage

        did_stream, line_count = get_stream_state()
        response_msg = AgentResponseMessage(
            content=agent_response,
            is_markdown=True,
            was_streamed=did_stream,
            streamed_line_count=line_count,
        )
        get_message_bus().emit(response_msg)

    except asyncio.CancelledError:
        from code_puppy.messaging import emit_warning

        emit_warning("Execution cancelled by user")
    except Exception as e:
        from code_puppy.messaging import emit_error

        emit_error(f"Error executing prompt: {str(e)}")
