"""CLI runner for Code Puppy.

This module is the public entry-point shim. It provides lazy access to the
public API so that simple CLI operations (--help, --version) are fast
without loading heavy dependencies.

Actual application logic lives in:
  - code_puppy.app_runner   - AppRunner class and main()
  - code_puppy.interactive_loop - interactive_mode() REPL
  - code_puppy.prompt_runner    - run_prompt_with_attachments(), execute_single_prompt()

Bootstrap strategy:
- main_entry() pre-parses sys.argv to detect --help/--version BEFORE heavy imports
- --help and --version use only stdlib (no Rich, no pydantic, no plugins)
- Full runtime (patches, plugins, config) only loads inside _run_full()
- Heavy submodules are deferred via __getattr__ for backward compat
"""

import os
import sys

# -----------------------------------------------------------------------------
# Lazy import registry: attribute -> import spec
# These are heavy modules that should only load when actually accessed.
# -----------------------------------------------------------------------------
_LAZY_IMPORTS: dict[str, tuple[str, str]] = {
    "AppRunner": ("code_puppy.app_runner", "AppRunner"),
    "main": ("code_puppy.app_runner", "main"),
    "shutdown_flag": ("code_puppy.app_runner", "shutdown_flag"),
    "interactive_mode": ("code_puppy.interactive_loop", "interactive_mode"),
    "execute_single_prompt": ("code_puppy.prompt_runner", "execute_single_prompt"),
    "run_prompt_with_attachments": (
        "code_puppy.prompt_runner",
        "run_prompt_with_attachments",
    ),
}


def __getattr__(name: str) -> object:
    """Lazy import heavy symbols on first access.

    This allows `from code_puppy.cli_runner import main` to work while
    deferring the heavy pydantic_ai, openai, anthropic imports until
    the symbol is actually accessed.

    Args:
        name: The attribute name being accessed on this module.

    Returns:
        The requested symbol or raises AttributeError if not found.

    Raises:
        AttributeError: If the requested attribute is not in _LAZY_IMPORTS.
    """
    if name in _LAZY_IMPORTS:
        module_path, attr_name = _LAZY_IMPORTS[name]
        mod = __import__(module_path, fromlist=[attr_name])
        value = getattr(mod, attr_name)
        # Cache on this module for subsequent accesses
        globals()[name] = value
        return value
    raise AttributeError(f"module 'code_puppy.cli_runner' has no attribute '{name}'")


def __dir__() -> list[str]:
    """Ensure dir(cli_runner) shows lazy-loaded symbols."""
    return sorted(set(globals().keys()) | set(_LAZY_IMPORTS.keys()))


# -----------------------------------------------------------------------------
# Synchronous entry point (installed as the ``code-puppy`` CLI command)
# -----------------------------------------------------------------------------


def main_entry() -> int | None:
    """Entry point for the installed CLI tool.

    Fast path: --help and --version are handled with minimal imports.
    Full path: All other invocations load the full runtime.
    """
    # Fast path: handle --help and --version without heavy imports
    # Only check the first positional argument (sys.argv[1]) to avoid
    # misinterpreting --help/--version when used as argument values
    # (e.g., `code-puppy -p --help` should treat --help as prompt, not trigger help)
    first_arg = sys.argv[1] if len(sys.argv) > 1 else None
    if first_arg in ("--help", "-h"):
        _print_help_fast()
        return None
    if first_arg in ("--version", "-V", "-v"):
        _print_version_fast()
        return None

    # Bridge mode must be visible before the full runtime imports plugins.
    # code_puppy.plugins.elixir_bridge freezes BRIDGE_ENABLED at import time,
    # so set the environment flag before _run_full() can load callbacks.
    if "--bridge-mode" in sys.argv:
        os.environ["CODE_PUPPY_BRIDGE"] = "1"

    # Full path: load everything and run
    return _run_full()


def _print_version_fast() -> None:
    """Print version using minimal imports."""
    try:
        import importlib.metadata

        version = importlib.metadata.version("codepp")
    except Exception:
        version = "0.0.0-dev"
    print(f"code-puppy {version}")


def _print_help_fast() -> None:
    """Print help text without Rich formatting."""
    try:
        import importlib.metadata

        version = importlib.metadata.version("codepp")
    except Exception:
        version = "0.0.0-dev"

    help_text = f"""code-puppy {version} - AI-powered coding assistant

Usage: pup [OPTIONS] [PROMPT]

Options:
  -h, --help            Show this help message and exit
  -v, -V, --version     Show version and exit
  -m, --model MODEL     Model to use (default: from config)
  -a, --agent AGENT     Agent to use (default: code-puppy)
  -p, --prompt PROMPT   Execute a single prompt and exit
  -i, --interactive     Run in interactive mode
  --bridge-mode         Enable bridge mode (sets CODE_PUPPY_BRIDGE=1)

Examples:
  pup                           Start interactive mode
  pup "explain this code"       Run single prompt
  pup -m claude-sonnet -i       Start interactive with specific model

For more information: https://github.com/anthropics/code-puppy
"""
    print(help_text)


def _run_full() -> int | None:
    """Run the full application with all imports.

    Returns:
        0 on KeyboardInterrupt, None otherwise.
    """
    import asyncio
    import traceback

    from code_puppy.errors import FatalError

    # Heavy setup - only done for actual execution, not --help/--version
    from code_puppy.pydantic_patches import apply_all_patches

    apply_all_patches()

    from code_puppy import plugins

    plugins.load_plugin_callbacks()

    try:
        from code_puppy.app_runner import main

        asyncio.run(main())
    except FatalError as exc:
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(exc.exit_code)
    except KeyboardInterrupt:
        # Note: Using sys.stderr for crash output - messaging system may not be available
        sys.stderr.write(traceback.format_exc())
        from importlib import import_module

        from code_puppy import config as puppy_config

        if getattr(puppy_config, "get_use_dbos")():
            DBOS = getattr(import_module("dbos"), "DBOS")
            DBOS.destroy()
        return 0
    finally:
        # Reset terminal on Unix-like systems (not Windows)
        from code_puppy.terminal_utils import reset_unix_terminal

        reset_unix_terminal()

    return None
