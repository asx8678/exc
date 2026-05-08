"""AppRunner class for Code Puppy.

Separates concerns of the main application lifecycle into distinct methods:
argument parsing, renderer setup, logo display, signal handling,
configuration/validation, and the top-level run dispatch.

Import-time optimization notes:
- All heavy imports (callbacks, config helpers, console, keymap, etc.) are
  deferred to runtime (inside methods) to keep --help/--version fast
- DBOS and heavy TUI imports are deferred to runtime (inside methods)
- This allows --help to be fast (~0.1s) while full runtime pays the import cost
- Rich console is only imported in setup_renderers() where it's used
"""

import argparse
import os
import sys
from collections.abc import Callable
from typing import TYPE_CHECKING, Any, TypeAlias, cast

from code_puppy import __version__

if TYPE_CHECKING:
    # Type-only imports for static analysis — not loaded at runtime
    from rich.console import Console
else:
    Console = Any

DBOSConfig: TypeAlias = dict[str, object]

# Module-level flag accessible to external code
shutdown_flag = False

# Lazy-loaded function references — populated on first use of run()
_interactive_mode: Callable[..., Any] | None = None
_execute_single_prompt: Callable[..., Any] | None = None


def _get_interactive_mode() -> Callable[..., Any]:
    """Lazy import interactive_mode to defer heavy TUI dependencies."""
    global _interactive_mode
    if _interactive_mode is None:
        from code_puppy.interactive_loop import interactive_mode

        _interactive_mode = interactive_mode
    return _interactive_mode


def _get_execute_single_prompt() -> Callable[..., Any]:
    """Lazy import execute_single_prompt to defer heavy dependencies."""
    global _execute_single_prompt
    if _execute_single_prompt is None:
        from code_puppy.prompt_runner import execute_single_prompt

        _execute_single_prompt = execute_single_prompt
    return _execute_single_prompt


def _log_gil_status() -> None:
    """Log whether the Python GIL is enabled or disabled (free-threaded mode)."""
    from code_puppy.messaging import emit_info

    try:
        gil_enabled = sys._is_gil_enabled()  # Python 3.13+
    except AttributeError:
        return  # Python < 3.13, GIL is always enabled

    if not gil_enabled:
        emit_info("🧵 Free-threaded Python active (GIL disabled)")
    else:
        emit_info(
            "🔒 GIL enabled (set PYTHON_GIL=0 or use python3.14t for free-threading)"
        )


class AppRunner:
    """Orchestrates all top-level concerns of the Code Puppy application.

    Each public method handles one distinct concern so that ``run()`` is a
    readable high-level description of startup order.
    """

    # ------------------------------------------------------------------
    # Argument parsing
    # ------------------------------------------------------------------

    def parse_args(self) -> argparse.Namespace:
        """Parse command-line arguments and return the namespace."""
        parser = argparse.ArgumentParser(
            description="Code Puppy - A code generation agent"
        )
        parser.add_argument(
            "--version",
            "-v",
            action="version",
            version=f"{__version__}",
            help="Show version and exit",
        )
        parser.add_argument(
            "--interactive", "-i", action="store_true", help="Run in interactive mode"
        )
        parser.add_argument(
            "--prompt",
            "-p",
            type=str,
            help="Execute a single prompt and exit (no interactive mode)",
        )
        parser.add_argument(
            "--agent",
            "-a",
            type=str,
            help="Specify which agent to use (e.g., --agent code-puppy)",
        )
        parser.add_argument(
            "--model",
            "-m",
            type=str,
            help="Specify which model to use (e.g., --model gpt-5)",
        )
        parser.add_argument(
            "--bridge-mode",
            action="store_true",
            help="Enable bridge mode (sets CODE_PUPPY_BRIDGE=1)",
        )
        parser.add_argument(
            "command",
            nargs="*",
            help="Run a single command (deprecated, use -p instead)",
        )
        return parser.parse_args()

    # ------------------------------------------------------------------
    # Renderer selection
    # ------------------------------------------------------------------

    def setup_renderers(self) -> tuple[Any, Any, Any]:
        """Create and start message renderers; returns (message_renderer, bus_renderer, display_console)."""
        from code_puppy.console import build_console
        from code_puppy.messaging import (
            RichConsoleRenderer,
            SynchronousInteractiveRenderer,
            get_global_queue,
            get_message_bus,
        )

        # Rich Console configuration — defend against silent downgrade to plain text.
        # Respect CODE_PUPPY_NO_COLOR (off) and CODE_PUPPY_FORCE_COLOR (on) escape hatches.
        display_console = build_console(soft_wrap=False)

        # Legacy renderer for backward compatibility (emits via get_global_queue)
        message_queue = get_global_queue()
        message_renderer: Any = SynchronousInteractiveRenderer(
            message_queue, display_console
        )
        message_renderer.start()

        # New MessageBus renderer for structured messages (tools emit here)
        message_bus = get_message_bus()
        bus_renderer: Any = RichConsoleRenderer(message_bus, display_console)
        bus_renderer.start()

        return message_renderer, bus_renderer, display_console

    # ------------------------------------------------------------------
    # Logo / banner display
    # ------------------------------------------------------------------

    def show_logo(self, args: argparse.Namespace, display_console: Console) -> None:
        """Display the Code Puppy ASCII logo when entering interactive mode."""
        if args.prompt:
            return  # Skip logo in prompt-only mode

        try:
            import pyfiglet

            intro_lines = pyfiglet.figlet_format(
                "CODE PUPPY", font="ansi_shadow"
            ).split("\n")

            gradient_colors = ["bright_blue", "bright_cyan", "bright_green"]
            display_console.print("\n")

            lines = []
            for line_num, line in enumerate(intro_lines):
                if line.strip():
                    color_idx = min(line_num // 2, len(gradient_colors) - 1)
                    color = gradient_colors[color_idx]
                    lines.append(f"[{color}]{line}[/{color}]")
                else:
                    lines.append("")
            display_console.print("\n".join(lines))
        except ImportError:
            from code_puppy.messaging import emit_system_message

            emit_system_message("🐶 Code Puppy is Loading...")

    # ------------------------------------------------------------------
    # Signal handling setup
    # ------------------------------------------------------------------

    def setup_signals(self) -> None:
        """Configure OS signal handlers (Windows + uvx protective handler)."""
        try:
            from code_puppy.terminal_utils import (
                disable_windows_ctrl_c,
                reset_windows_terminal_full,
                set_keep_ctrl_c_disabled,
            )
            from code_puppy.uvx_detection import should_use_alternate_cancel_key

            if should_use_alternate_cancel_key():
                disable_windows_ctrl_c()
                set_keep_ctrl_c_disabled(True)

                print(
                    "🔧 Detected uvx launch on Windows - using Ctrl+K for cancellation "
                    "(Ctrl+C is disabled to prevent terminal issues)"
                )

                import signal

                def _uvx_protective_sigint_handler(_sig: int, _frame: object) -> None:
                    """Protective SIGINT handler for Windows+uvx."""
                    reset_windows_terminal_full()
                    disable_windows_ctrl_c()

                signal.signal(signal.SIGINT, _uvx_protective_sigint_handler)
        except ImportError:
            pass  # uvx_detection module not available, ignore

    # ------------------------------------------------------------------
    # Plugin loading (config / environment)
    # ------------------------------------------------------------------

    def load_api_keys(self) -> None:
        """Load API keys from puppy.cfg into environment variables."""
        from code_puppy.config import (
            load_api_keys_to_environment,  # type: ignore[attr-defined]
        )

        load_api_keys_to_environment()

    def _get_dbos_config(self, current_version: str) -> "DBOSConfig":
        """Build DBOS configuration dict."""
        import time

        from code_puppy.config import DBOS_DATABASE_URL

        dbos_app_version = os.environ.get(
            "DBOS_APP_VERSION", f"{current_version}-{int(time.time() * 1000)}"
        )
        return {
            "name": "dbos-code-puppy",
            "system_database_url": DBOS_DATABASE_URL,
            "run_admin_server": False,
            "conductor_key": os.environ.get("DBOS_CONDUCTOR_KEY"),
            "log_level": os.environ.get("DBOS_LOG_LEVEL", "ERROR"),
            "application_version": dbos_app_version,
        }

    # ------------------------------------------------------------------
    # Agent / model instantiation
    # ------------------------------------------------------------------

    def configure_agent(self, args: argparse.Namespace) -> None:
        """Validate and apply --model / --agent flags from the command line."""
        from code_puppy.config import (  # type: ignore[attr-defined]
            _validate_model_exists,
            set_model_name,
        )
        from code_puppy.messaging import emit_error, emit_system_message

        if args.model:
            model_name = args.model.strip()
            # Early-set model so config is initialised correctly
            set_model_name(model_name)
            try:
                if not _validate_model_exists(model_name):
                    from code_puppy.model_factory import ModelFactory

                    models_config = ModelFactory.load_config()
                    available_models = (
                        list(models_config.keys()) if models_config else []
                    )
                    emit_error(f"Model '{model_name}' not found")
                    emit_system_message(
                        f"Available models: {', '.join(available_models)}"
                    )
                    sys.exit(1)
                emit_system_message(f"🎯 Using model: {model_name}")
            except SystemExit:
                raise
            except Exception as e:
                emit_error(f"Error validating model: {str(e)}")
                from code_puppy.error_logging import log_error

                log_error(e, context="Model validation error")
                sys.exit(1)

        if args.agent:
            from code_puppy.agents.agent_manager import (
                get_available_agents,
                set_current_agent,
            )

            agent_name = args.agent.lower()
            try:
                available_agents = get_available_agents()
                if agent_name not in available_agents:
                    emit_error(f"Agent '{agent_name}' not found")
                    emit_system_message(
                        f"Available agents: {', '.join(available_agents.keys())}"
                    )
                    sys.exit(1)
                set_current_agent(agent_name)
                emit_system_message(f"🤖 Using agent: {agent_name}")
            except SystemExit:
                raise
            except Exception as e:
                emit_error(f"Error setting agent: {str(e)}")
                from code_puppy.error_logging import log_error

                log_error(e, context="Agent setup error")
                sys.exit(1)

    # ------------------------------------------------------------------
    # REPL loop dispatch (run)
    # ------------------------------------------------------------------

    async def _run_bridge_mode(self) -> None:
        """Run as a JSON-RPC bridge worker until shutdown.

        The bridge plugin's startup callback has already created the bridge
        controller and started a background stdin reader task. This method keeps
        the event loop alive through the plugin's public shutdown waiter instead
        of polling plugin globals or controller internals.
        """
        from code_puppy.plugins.elixir_bridge import await_shutdown

        try:
            await await_shutdown()
        except RuntimeError as exc:
            if "bridge plugin not activated" not in str(exc):
                raise
            sys.stderr.write(
                "ERROR: --bridge-mode was set but the bridge plugin did not "
                "activate.\n"
                "  Likely cause: CODE_PUPPY_BRIDGE was not set before "
                "code_puppy.plugins.elixir_bridge\n"
                "  was imported, so BRIDGE_ENABLED was frozen as False.\n"
                "  Try: CODE_PUPPY_BRIDGE=1 pup  (instead of pup --bridge-mode)\n"
            )
            sys.stderr.flush()
            raise RuntimeError(
                "Bridge mode requested but bridge plugin not activated"
            ) from exc

    async def run(self) -> None:
        """Full application lifecycle: parse → setup → validate → dispatch."""
        global shutdown_flag

        # Deferred imports to keep --help/--version fast
        from code_puppy import callbacks
        from code_puppy.config import (  # type: ignore[attr-defined]
            ensure_config_exists,
            get_use_dbos,
            initialize_command_history_file,
        )
        from code_puppy.config_package import env_bool
        from code_puppy.keymap import KeymapError, validate_cancel_agent_key

        args = self.parse_args()

        # --bridge-mode sets CODE_PUPPY_BRIDGE=1. cli_runner.main_entry() does
        # this before importing app_runner; repeat the explicit assignment for
        # callers that instantiate AppRunner directly.
        if getattr(args, "bridge_mode", False):
            os.environ["CODE_PUPPY_BRIDGE"] = "1"
        bridge_mode_enabled = os.environ.get("CODE_PUPPY_BRIDGE") == "1"

        message_renderer = None
        bus_renderer = None

        if bridge_mode_enabled:
            # Bridge stdout is the JSON-RPC wire. Do not start Rich/Owl/Textual
            # renderers and do not print the logo; both would corrupt framing.
            tui_mode = False
        else:
            # Check TUI mode early to skip legacy renderers — Textual handles all output
            from code_puppy.tui.launcher import is_tui_enabled

            tui_mode = is_tui_enabled() and not args.prompt

            if tui_mode:
                # In TUI mode, don't start legacy renderer threads — they fight Textual for the terminal
                message_renderer = None
                bus_renderer = None
            else:
                message_renderer, bus_renderer, display_console = self.setup_renderers()
                self.show_logo(args, display_console)

        initialize_command_history_file()
        from code_puppy.messaging import emit_error, emit_system_message

        if not bridge_mode_enabled:
            ensure_config_exists()

        try:
            validate_cancel_agent_key()
        except KeymapError as e:
            emit_error(str(e))
            sys.exit(1)

        if not tui_mode and not bridge_mode_enabled:
            self.setup_signals()
        self.load_api_keys()
        self.configure_agent(args)

        current_version = __version__
        if not bridge_mode_enabled:
            no_version_update = env_bool("NO_VERSION_UPDATE", default=False)
            if no_version_update:
                emit_system_message(f"Current version: {current_version}")
                emit_system_message(
                    "Update phase disabled because NO_VERSION_UPDATE is set to 1 or true"
                )
            else:
                if len(callbacks.get_callbacks("version_check")):
                    await callbacks.on_version_check(current_version)
                else:
                    from code_puppy.version_checker import (
                        check_version_background,
                        default_version_mismatch_behavior,
                    )

                    default_version_mismatch_behavior(current_version)
                    # Fire background version check (non-blocking refresh)
                    import asyncio

                    asyncio.create_task(check_version_background(current_version))

            # Eagerly probe Elixir transport so failures surface with a clear
            # banner instead of a cryptic traceback deep inside prompt rendering.
            try:
                from code_puppy.elixir_transport_helpers import get_transport

                get_transport()
            except Exception as _transport_err:
                from code_puppy.messaging import emit_error, emit_warning

                emit_error(
                    "Elixir control-plane failed to start:\n"
                    f" {type(_transport_err).__name__}: {_transport_err}\n"
                    "Remediation:\n"
                    " * Run manually: cd elixir/code_puppy_control && mix code_puppy.stdio_service\n"
                    " * Check elixir is installed: which elixir\n"
                    " * To boot anyway in degraded mode: export PUP_ALLOW_ELIXIR_DEGRADED=1"
                )
                if os.environ.get("PUP_ALLOW_ELIXIR_DEGRADED") != "1":
                    raise
                emit_warning(
                    "Continuing in degraded mode (PUP_ALLOW_ELIXIR_DEGRADED=1)"
                )

        await callbacks.on_startup()

        # Log free-threading (no-GIL) status only for human-facing CLI modes.
        if not bridge_mode_enabled:
            _log_gil_status()

        # Register workflow state callback handlers for tracking flags. Keep this
        # in bridge mode as bridge requests may still touch workflow state.
        from code_puppy.workflow_state import register_callback_handlers

        cast(Callable[[], None], register_callback_handlers)()

        # Initialize DBOS if not disabled (lazy import — DBOS is heavy and only needed here).
        # Bridge mode skips DBOS to avoid any non-protocol stdout from DBOS startup.
        dbos_enabled = get_use_dbos() and not bridge_mode_enabled
        if dbos_enabled:
            from importlib import import_module

            from code_puppy.dbos_utils import is_dbos_initialized

            DBOS = getattr(import_module("dbos"), "DBOS")

            dbos_config = self._get_dbos_config(current_version)
            try:
                DBOS(config=dbos_config)
                DBOS.launch()
            except Exception as e:
                emit_error(f"Error initializing DBOS: {e}")
                from code_puppy.error_logging import log_error

                log_error(e, context="DBOS initialization error")
                sys.exit(1)

            # Verify DBOS actually initialized despite no exception
            if not is_dbos_initialized():
                emit_error(
                    "DBOS initialization verification failed. Workflow durability may be unavailable."
                )

        shutdown_flag = False
        try:
            if bridge_mode_enabled:
                await self._run_bridge_mode()
            else:
                initial_command = None
                prompt_only_mode = False

                if args.prompt:
                    initial_command = args.prompt
                    prompt_only_mode = True
                elif args.command:
                    initial_command = " ".join(args.command)
                    prompt_only_mode = False

                if prompt_only_mode:
                    await _get_execute_single_prompt()(
                        initial_command, message_renderer
                    )
                elif tui_mode:
                    from code_puppy.tui.launcher import textual_interactive_mode

                    await textual_interactive_mode(
                        message_renderer, initial_command=initial_command or ""
                    )
                else:
                    # Default to interactive mode (no args = same as -i)
                    await _get_interactive_mode()(
                        message_renderer, initial_command=initial_command
                    )
        finally:
            if message_renderer:
                message_renderer.stop()
            if bus_renderer:
                bus_renderer.stop()
            await callbacks.on_shutdown()
            if dbos_enabled:
                from importlib import import_module

                DBOS = getattr(import_module("dbos"), "DBOS")
                DBOS.destroy()


async def main() -> None:
    """Main async entry point for Code Puppy CLI."""
    runner = AppRunner()
    await runner.run()
