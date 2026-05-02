"""Interactive REPL loop for Code Puppy — houses interactive_mode() and helpers."""

import asyncio
import sys
from pathlib import Path

from code_puppy import config as puppy_config
from code_puppy.command_line.attachments import parse_prompt_attachments
from code_puppy.config import finalize_autosave_session, save_command_to_history
from code_puppy.config_package import env_bool
from code_puppy.keymap import get_cancel_agent_display_name
from code_puppy.prompt_runner import run_prompt_with_attachments
from code_puppy.repl_session import (
    record_command,
    save_session,
)
from code_puppy.terminal_utils import (
    print_truecolor_warning,
    reset_windows_terminal_ansi,
    reset_windows_terminal_full,
)


def _command_history_file():
    return globals().get("COMMAND_HISTORY_FILE", puppy_config.COMMAND_HISTORY_FILE)


def _autosave_dir():
    return globals().get("AUTOSAVE_DIR", puppy_config.AUTOSAVE_DIR)


def __getattr__(name: str):
    if name == "COMMAND_HISTORY_FILE":
        return _command_history_file()
    if name == "AUTOSAVE_DIR":
        return _autosave_dir()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def _sync_history_from_result(agent, result) -> None:
    """Sync agent message history from result.all_messages().

    pydantic-ai's all_messages() already returns a list; this helper
    deduplicates the sync logic across multiple call sites.
    """
    if hasattr(result, "all_messages"):
        agent.set_message_history(result.all_messages())


async def interactive_mode(message_renderer, initial_command: str = None) -> None:
    """Run the agent in interactive mode."""
    from code_puppy.command_line.command_handler import handle_command

    display_console = message_renderer.console
    from code_puppy.messaging import emit_info, emit_system_message

    emit_system_message(
        "Type '/exit', '/quit', or press Ctrl+D to exit the interactive mode."
    )
    emit_system_message("Type 'clear' to reset the conversation history.")
    emit_system_message("Type /help to view all commands")
    emit_system_message(
        "Type @ for path completion, or /model to pick a model. Toggle multiline with Alt+M or F2; newline: Ctrl+J."
    )
    emit_system_message("Paste images: Ctrl+V (even on Mac!), F3, or /paste command.")
    import platform

    if platform.system() == "Darwin":
        emit_system_message(
            "💡 macOS tip: Use Ctrl+V (not Cmd+V) to paste images in terminal."
        )
    cancel_key = get_cancel_agent_display_name()
    emit_system_message(
        f"Press {cancel_key} during processing to cancel the current task or inference. Use Ctrl+X to interrupt running shell commands."
    )
    emit_system_message(
        "Use /autosave_load to manually load a previous autosave session."
    )
    emit_system_message(
        "Use /diff to configure diff highlighting colors for file changes."
    )
    emit_system_message("To re-run the tutorial, use /tutorial.")
    emit_system_message("!<command> to run shell commands directly (e.g., !git status)")
    try:
        from code_puppy.command_line.motd import print_motd
        from code_puppy.tools.common import console

        print_motd(console, force=False)
    except Exception as e:
        from code_puppy.messaging import emit_warning

        emit_warning(f"MOTD error: {e}")
        from code_puppy.error_logging import log_error

        log_error(e, context="MOTD display error")

    # Print truecolor warning LAST so it's the most visible thing on startup
    # Big ugly red box should be impossible to miss! 🔴
    print_truecolor_warning(display_console)

    # Shell pass-through for initial_command: !<cmd> bypasses the agent
    if initial_command:
        from code_puppy.command_line.shell_passthrough import (
            execute_shell_passthrough,
            is_shell_passthrough,
        )

        if is_shell_passthrough(initial_command):
            execute_shell_passthrough(initial_command)
            initial_command = None

    if initial_command:
        from code_puppy.agents import get_current_agent
        from code_puppy.messaging import emit_info, emit_success, emit_system_message

        agent = get_current_agent()
        emit_info(f"Processing initial command: {initial_command}")

        try:
            # Check if any tool is waiting for user input before showing spinner
            try:
                from code_puppy.tools.command_runner import is_awaiting_user_input

                awaiting_input = is_awaiting_user_input()
            except ImportError:
                awaiting_input = False

            # Run with or without spinner based on whether we're awaiting input
            response, agent_task = await run_prompt_with_attachments(
                agent,
                initial_command,
                spinner_console=display_console,
                use_spinner=not awaiting_input,
            )
            if response is not None:
                agent_response = response.output

                # Update the agent's message history with the complete conversation
                # including the final assistant response
                _sync_history_from_result(agent, response)

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

                emit_success("🐶 Continuing in Interactive Mode")
                emit_system_message(
                    "Your command and response are preserved in the conversation history."
                )

        except Exception as e:
            from code_puppy.messaging import emit_error

            emit_error(f"Error processing initial command: {str(e)}")
            from code_puppy.error_logging import log_error

            log_error(e, context="Initial command processing error")

    # Check if prompt_toolkit is installed
    get_input_with_combined_completion = None
    get_prompt_with_active_model = None
    try:
        from code_puppy.command_line.prompt_toolkit_completion import (
            get_input_with_combined_completion,
            get_prompt_with_active_model,
        )
    except ImportError:
        from code_puppy.messaging import emit_warning

        emit_warning("prompt_toolkit not available. Falling back to basic input.")

    # Autosave loading is now manual - use /autosave_load command

    # Auto-run tutorial on first startup
    try:
        from code_puppy.command_line.onboarding_wizard import should_show_onboarding

        if should_show_onboarding():
            import concurrent.futures

            from code_puppy.command_line.onboarding_wizard import run_onboarding_wizard
            from code_puppy.config import set_model_name
            from code_puppy.messaging import emit_info

            with concurrent.futures.ThreadPoolExecutor() as executor:
                future = executor.submit(lambda: asyncio.run(run_onboarding_wizard()))
                result = future.result(timeout=300)

            if result == "chatgpt":
                emit_info("🔐 Starting ChatGPT OAuth flow...")
                from code_puppy.plugins.chatgpt_oauth.oauth_flow import run_oauth_flow

                run_oauth_flow()
                set_model_name("chatgpt-gpt-5.3-codex")
            elif result == "claude":
                emit_info("🔐 Starting Claude Code OAuth flow...")
                from code_puppy.plugins.claude_code_oauth.register_callbacks import (
                    _perform_authentication,
                )

                _perform_authentication()
                set_model_name("claude-code-claude-opus-4-6")
            elif result == "completed":
                emit_info("🎉 Tutorial complete! Happy coding!")
            elif result == "skipped":
                emit_info("⏭️ Tutorial skipped. Run /tutorial anytime!")
    except Exception as e:
        from code_puppy.messaging import emit_warning

        emit_warning(f"Tutorial auto-start failed: {e}")
        from code_puppy.error_logging import log_error

        log_error(e, context="Tutorial auto-start error")

    # Track the current agent task for cancellation on quit
    current_agent_task = None

    while True:
        from code_puppy.agents.agent_manager import get_current_agent
        from code_puppy.messaging import emit_info

        # Get the custom prompt from the current agent, or use default
        current_agent = get_current_agent()
        user_prompt = current_agent.get_user_prompt() or "Enter your coding task:"

        emit_info(f"{user_prompt}\n")

        try:
            # Use prompt_toolkit for enhanced input with path completion
            if get_input_with_combined_completion is not None:
                # Windows-specific: Reset terminal state before prompting
                reset_windows_terminal_ansi()

                # Use the async version of get_input_with_combined_completion
                task = await get_input_with_combined_completion(
                    get_prompt_with_active_model(), history_file=_command_history_file()
                )

                # Windows+uvx: Re-disable Ctrl+C after prompt_toolkit
                # (prompt_toolkit restores console mode which re-enables Ctrl+C)
                try:
                    from code_puppy.terminal_utils import ensure_ctrl_c_disabled

                    ensure_ctrl_c_disabled()
                except ImportError:
                    pass
            else:
                # Fall back to basic input if prompt_toolkit is not available
                task = input(">>> ")

        except KeyboardInterrupt:
            # Handle Ctrl+C - cancel input and continue
            # Windows-specific: Reset terminal state after interrupt to prevent
            # the terminal from becoming unresponsive (can't type characters)
            reset_windows_terminal_full()
            # Stop wiggum mode on Ctrl+C
            from code_puppy.command_line.wiggum_state import (
                is_wiggum_active,
                stop_wiggum,
            )
            from code_puppy.messaging import emit_warning

            if is_wiggum_active():
                stop_wiggum()
                emit_warning("\n🍩 Wiggum loop stopped!")
            else:
                emit_warning("\nInput cancelled")
            continue
        except EOFError:
            # Handle Ctrl+D - exit the application
            from code_puppy.messaging import emit_success

            emit_success("\nGoodbye! (Ctrl+D)")

            # Save REPL session state
            save_session()

            # Cancel any running agent task for clean shutdown
            if current_agent_task and not current_agent_task.done():
                emit_info("Cancelling running agent task...")
                current_agent_task.cancel()
                try:
                    await current_agent_task
                except asyncio.CancelledError:
                    pass  # Expected when cancelling

            break

        # Record command in REPL session history
        if task.strip():
            record_command(task)

        # Shell pass-through: !<command> executes directly, bypassing the agent
        from code_puppy.command_line.shell_passthrough import (
            execute_shell_passthrough,
            is_shell_passthrough,
        )

        if is_shell_passthrough(task):
            execute_shell_passthrough(task)
            continue

        # Check for exit commands (plain text or command form)
        if task.strip().lower() in ["exit", "quit"] or task.strip().lower() in [
            "/exit",
            "/quit",
        ]:
            from code_puppy.messaging import emit_success

            emit_success("Goodbye!")

            # Cancel any running agent task for clean shutdown
            if current_agent_task and not current_agent_task.done():
                emit_info("Cancelling running agent task...")
                current_agent_task.cancel()
                try:
                    await current_agent_task
                except asyncio.CancelledError:
                    pass  # Expected when cancelling

            # The renderer is stopped in the finally block of main().
            break

        # Check for clear command (supports both `clear` and `/clear`)
        if task.strip().lower() in ("clear", "/clear"):
            from code_puppy.command_line.clipboard import get_clipboard_manager
            from code_puppy.messaging import (
                emit_info,
                emit_system_message,
                emit_warning,
            )

            agent = get_current_agent()
            new_session_id = finalize_autosave_session()
            agent.clear_message_history()
            emit_warning("Conversation history cleared!")
            emit_system_message("The agent will not remember previous interactions.")
            emit_info(f"Auto-save session rotated to: {new_session_id}")

            # Also clear pending clipboard images
            clipboard_manager = get_clipboard_manager()
            clipboard_count = clipboard_manager.get_pending_count()
            clipboard_manager.clear_pending()
            if clipboard_count > 0:
                emit_info(f"Cleared {clipboard_count} pending clipboard image(s)")
            continue

        # Parse attachments first so leading paths aren't misread as commands
        processed_for_commands = parse_prompt_attachments(task)
        cleaned_for_commands = (processed_for_commands.prompt or "").strip()

        # Handle / commands based on cleaned prompt (after stripping attachments)
        if cleaned_for_commands.startswith("/"):
            try:
                command_result = handle_command(cleaned_for_commands)
            except Exception as e:
                from code_puppy.messaging import emit_error

                emit_error(f"Command error: {e}")
                from code_puppy.error_logging import log_error

                log_error(e, context="Slash command handling error")
                # Continue interactive loop instead of exiting
                continue
            if command_result is True:
                continue
            elif isinstance(command_result, str):
                if command_result == "__AUTOSAVE_LOAD__":
                    # Handle async autosave loading
                    try:
                        # Check if we're in a real interactive terminal
                        # (not pexpect/tests) - interactive picker requires proper TTY
                        use_interactive_picker = (
                            sys.stdin.isatty() and sys.stdout.isatty()
                        )

                        # Allow environment variable override for tests
                        if env_bool("CODE_PUPPY_NO_TUI", default=False):
                            use_interactive_picker = False

                        if use_interactive_picker:
                            # Use interactive picker for terminal sessions
                            from code_puppy.agents.agent_manager import (
                                get_current_agent,
                            )
                            from code_puppy.command_line.autosave_menu import (
                                interactive_autosave_picker,
                            )
                            from code_puppy.config import (
                                set_current_autosave_from_session_name,
                            )
                            from code_puppy.messaging import (
                                emit_error,
                                emit_success,
                                emit_warning,
                            )
                            from code_puppy.session_storage import (
                                load_session_with_hashes,
                                restore_autosave_interactively,
                            )

                            chosen_session = await interactive_autosave_picker()

                            if not chosen_session:
                                emit_warning("Autosave load cancelled")
                                continue

                            # Load the session (including persisted compacted hashes)
                            base_dir = Path(_autosave_dir())
                            history, compacted_hashes = load_session_with_hashes(
                                chosen_session, base_dir
                            )

                            agent = get_current_agent()
                            agent.set_message_history(history)
                            agent.restore_compacted_hashes(compacted_hashes)

                            # Set current autosave session
                            set_current_autosave_from_session_name(chosen_session)

                            total_tokens = sum(
                                agent.estimate_tokens_for_message(msg)
                                for msg in history
                            )
                            session_path = base_dir / f"{chosen_session}.pkl"

                            emit_success(
                                f"✅ Autosave loaded: {len(history)} messages ({total_tokens} tokens)\n"
                                f"📁 From: {session_path}"
                            )

                            # Display recent message history for context
                            from code_puppy.command_line.autosave_menu import (
                                display_resumed_history,
                            )

                            display_resumed_history(history)
                        else:
                            # Fall back to old text-based picker for tests/non-TTY environments
                            await restore_autosave_interactively(Path(_autosave_dir()))

                    except Exception as e:
                        from code_puppy.messaging import emit_error

                        emit_error(f"Failed to load autosave: {e}")
                        from code_puppy.error_logging import log_error

                        log_error(e, context="Autosave load error")
                    continue
                else:
                    # Command returned a prompt to execute
                    task = command_result
            elif command_result is False:
                # Command not recognized, continue with normal processing
                pass

        if task.strip():
            # Write to the secret file for permanent history with timestamp
            save_command_to_history(task)

            try:
                # No need to get agent directly - use manager's run methods

                # Use our custom helper to enable attachment handling with spinner support
                result, current_agent_task = await run_prompt_with_attachments(
                    current_agent, task, spinner_console=message_renderer.console
                )
                # Check if the task was cancelled (but don't show message if we just killed processes)
                if result is None:
                    # Windows-specific: Reset terminal state after cancellation
                    reset_windows_terminal_ansi()
                    # Re-disable Ctrl+C if needed (uvx mode)
                    try:
                        from code_puppy.terminal_utils import ensure_ctrl_c_disabled

                        ensure_ctrl_c_disabled()
                    except ImportError:
                        pass
                    # Stop wiggum mode on cancellation
                    from code_puppy.command_line.wiggum_state import (
                        is_wiggum_active,
                        stop_wiggum,
                    )

                    if is_wiggum_active():
                        stop_wiggum()
                        from code_puppy.messaging import emit_warning

                        emit_warning("🍩 Wiggum loop stopped due to cancellation")
                    continue
                # Get the structured response
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

                # Update the agent's message history with the complete conversation
                # including the final assistant response. The history_processors callback
                # may not capture the final message, so we use result.all_messages()
                # to ensure the autosave includes the complete conversation.
                _sync_history_from_result(current_agent, result)

                # Ensure console output is flushed before next prompt
                # This fixes the issue where prompt doesn't appear after agent response
                if hasattr(display_console.file, "flush"):
                    display_console.file.flush()

                # Wait for all messages to be rendered using condition variable
                # instead of polling with asyncio.sleep(0.1). The condition is
                # signaled when the message queue becomes empty (all messages
                # processed by renderers). Event-driven with 0.5s timeout safety.
                from code_puppy.messaging import wait_for_messages_rendered

                await wait_for_messages_rendered(timeout=0.5)

            except asyncio.CancelledError:
                raise
            except Exception as e:
                from code_puppy.messaging.queue_console import get_queue_console

                get_queue_console().print_exception()
                from code_puppy.error_logging import log_error

                log_error(e, context="Agent response rendering error")

            # Auto-save session if enabled (moved outside the try block to avoid being swallowed)
            from code_puppy.config import auto_save_session_if_enabled

            auto_save_session_if_enabled()

            # ================================================================
            # WIGGUM LOOP: Re-run prompt if wiggum mode is active
            # ================================================================
            from code_puppy.command_line.wiggum_state import (
                get_wiggum_prompt,
                increment_wiggum_count,
                is_wiggum_active,
                stop_wiggum,
            )

            while is_wiggum_active():
                # Don't re-loop into a dead Elixir control-plane.
                # is_using_elixir() pings the transport; if it's down and we're not in
                # degraded mode, the next finalize_autosave_session would crash the REPL.
                import os

                from code_puppy.runtime_state import is_using_elixir

                if (
                    not is_using_elixir()
                    and os.environ.get("PUP_ALLOW_ELIXIR_DEGRADED") != "1"
                ):
                    from code_puppy.messaging import emit_error

                    emit_error(
                        "Wiggum stopping: Elixir control-plane is unreachable. "
                        "Set PUP_ALLOW_ELIXIR_DEGRADED=1 to continue in degraded mode."
                    )
                    stop_wiggum()
                    break

                try:
                    wiggum_prompt = get_wiggum_prompt()
                    if not wiggum_prompt:
                        stop_wiggum()
                        break

                    # Increment and show debug message
                    loop_num = increment_wiggum_count()
                    from code_puppy.messaging import (
                        emit_info,
                        emit_system_message,
                        emit_warning,
                    )

                    emit_warning(f"\n🍩 WIGGUM RELOOPING! (Loop #{loop_num})")
                    emit_system_message(f"Re-running prompt: {wiggum_prompt}")

                    # Reset context/history for fresh start
                    new_session_id = finalize_autosave_session()
                    current_agent.clear_message_history()

                    # Clear token ledger for fresh cost tracking per wiggum loop
                    # (design fix: each wiggum iteration should have independent accounting)
                    current_agent._state.get_token_ledger().clear()
                    emit_info(f"💰 Token ledger reset for wiggum loop #{loop_num}")

                    emit_system_message(
                        f"Context cleared. Session rotated to: {new_session_id}"
                    )

                    # Small delay to let user see the debug message

                    await asyncio.sleep(0.5)

                    try:
                        # Re-run the wiggum prompt
                        result, current_agent_task = await run_prompt_with_attachments(
                            current_agent,
                            wiggum_prompt,
                            spinner_console=message_renderer.console,
                        )

                        if result is None:
                            # Cancelled - stop wiggum mode
                            emit_warning("Wiggum loop cancelled by user")
                            stop_wiggum()
                            break

                        # Get the structured response
                        agent_response = result.output

                        # Emit structured message for proper markdown rendering
                        from code_puppy.agents.event_stream_handler import (
                            get_stream_state,
                        )

                        did_stream, line_count = get_stream_state()
                        response_msg = AgentResponseMessage(
                            content=agent_response,
                            is_markdown=True,
                            was_streamed=did_stream,
                            streamed_line_count=line_count,
                        )
                        get_message_bus().emit(response_msg)

                        # Update message history
                        _sync_history_from_result(current_agent, result)

                        # Flush console
                        if hasattr(display_console.file, "flush"):
                            display_console.file.flush()

                        # Wait for messages to render using condition variable
                        # instead of polling with asyncio.sleep(0.1)
                        await wait_for_messages_rendered(timeout=0.5)

                        # Auto-save
                        auto_save_session_if_enabled()

                    except KeyboardInterrupt:
                        emit_warning("\n🍩 Wiggum loop interrupted by Ctrl+C")
                        stop_wiggum()
                        break

                except asyncio.CancelledError:
                    # Re-raise so the outer loop's cancellation handling fires.
                    raise
                except Exception as exc:
                    from code_puppy.error_logging import log_error as _log_error
                    from code_puppy.messaging import emit_error as _emit_error

                    _log_error(exc, context="wiggum loop iteration")
                    _emit_error(
                        f"Wiggum stopping due to error in loop iteration: "
                        f"{type(exc).__name__}: {exc}"
                    )
                    stop_wiggum()
                    break

            # Re-disable Ctrl+C if needed (uvx mode) - must be done after
            # each iteration as various operations may restore console mode
            try:
                from code_puppy.terminal_utils import ensure_ctrl_c_disabled

                ensure_ctrl_c_disabled()
            except ImportError:
                pass
