"""Launcher for the Textual TUI mode.

Provides textual_interactive_mode() which is the Textual equivalent of
interactive_mode() from interactive_loop.py. Called by AppRunner when
TUI mode is enabled.

Deprecation notice:
    The Textual TUI is being phased out in favour of the CLI interface.
    Set PUP_TUI_DEPRECATED=1 alongside CODE_PUPPY_TUI=1 to receive an
    explicit deprecation warning before the TUI launches.  See
    docs/TUI_CLI_AUDIT.md for the full migration timeline.
"""

import sys
import warnings

from code_puppy.config_package import env_bool

# ---------------------------------------------------------------------------
# Feature-flag helpers
# ---------------------------------------------------------------------------


def is_tui_enabled() -> bool:
    """Check if Textual TUI mode is enabled.

    The Textual TUI is opt-in while still under development.
    Set CODE_PUPPY_TUI=1 to enable it. Otherwise the classic
    prompt_toolkit UI is used.
    """
    return env_bool("CODE_PUPPY_TUI", default=False)


def is_tui_deprecated() -> bool:
    """Check whether the TUI deprecation warning flag is set.

    Returns True only when PUP_TUI_DEPRECATED is truthy.
    This flag is *advisory* — it does **not** prevent the TUI from
    launching; it only controls whether a warning is emitted.
    """
    return env_bool("PUP_TUI_DEPRECATED", default=False)


# ---------------------------------------------------------------------------
# Deprecation warning emission
# ---------------------------------------------------------------------------

_DEPRECATION_MESSAGE = (
    "⚠️  The Textual TUI is deprecated and will be removed in a future "
    "release.\n"
    "   The CLI (prompt_toolkit) interface already has full feature parity "
    "— see docs/TUI_CLI_AUDIT.md.\n"
    "   To silence this warning, unset PUP_TUI_DEPRECATED or switch to "
    "the default CLI (remove CODE_PUPPY_TUI=1)."
)


def emit_tui_deprecation_warning() -> None:
    """Emit a user-visible TUI deprecation warning.

    Prints the warning to *stderr* (so it doesn't mix with Rich/Textual
    rendering on stdout) **and** fires a ``DeprecationWarning`` so that
    automated tooling that captures warnings still sees it.

    Call this only when *both* ``is_tui_enabled()`` *and*
    ``is_tui_deprecated()`` are True.
    """
    print(_DEPRECATION_MESSAGE, file=sys.stderr)
    warnings.warn(
        "The Textual TUI is deprecated; prefer the CLI interface.",
        category=DeprecationWarning,
        stacklevel=2,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


async def textual_interactive_mode(
    message_renderer=None, initial_command: str = None
) -> None:
    """Run Code Puppy in Textual TUI mode.

    This replaces interactive_mode() when TUI mode is enabled.

    If ``PUP_TUI_DEPRECATED`` is set, a deprecation warning is emitted
    before the Textual app launches.

    Args:
        message_renderer: Legacy renderer (not used in TUI mode, kept for API compat)
        initial_command: Optional initial command to execute on startup
    """
    # Emit deprecation warning when the flag is opted-in
    if is_tui_deprecated():
        emit_tui_deprecation_warning()

    from code_puppy.tui.app import CodePuppyApp

    app = CodePuppyApp()

    # If there's an initial command, queue it for execution after mount
    if initial_command:
        app._initial_command = initial_command

    # Run the Textual app
    await app.run_async()
