"""Universal clipboard support with OSC 52 terminal escape.

Ported from pi-mono-main packages/coding-agent/src/utils/clipboard.ts.

OSC 52 is an operating system command escape sequence that sets the system
clipboard via the terminal emulator. It works transparently over SSH and mosh
connections, unlike native tools (pbcopy, xclip) which only work locally.

Supported terminals: iTerm2, kitty, alacritty, WezTerm, foot, Windows Terminal,
tmux (with set-clipboard on), and most modern terminal emulators.

Usage:
    from code_puppy.utils.clipboard import copy_to_clipboard

    copy_to_clipboard("hello world")  # Sets clipboard via best available method
"""

import base64
import logging
import os
import shutil
import subprocess
import sys

__all__ = ["copy_to_clipboard", "osc52_copy"]

logger = logging.getLogger(__name__)


def osc52_copy(text: str) -> None:
    """Set clipboard content via OSC 52 terminal escape sequence.

    This writes the escape sequence directly to stdout. The terminal
    emulator intercepts it and sets the system clipboard.

    Works over SSH/mosh connections — the escape is forwarded to the
    local terminal.

    Args:
        text: The text to copy to clipboard.

    Note:
        Some terminals limit OSC 52 payload size (commonly 100KB).
        Large content may be silently truncated by the terminal.
    """
    encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
    # OSC 52 format: ESC ] 52 ; c ; <base64> BEL
    # 'c' = clipboard selection (vs 'p' for primary on X11)
    sys.stdout.write(f"\x1b]52;c;{encoded}\x07")
    sys.stdout.flush()


def _try_native_clipboard(text: str) -> bool:
    """Try to copy using platform-native clipboard tools.

    Returns True if successful, False otherwise.
    """
    platform = sys.platform

    # macOS
    if platform == "darwin":
        if shutil.which("pbcopy"):
            try:
                subprocess.run(
                    ["pbcopy"],
                    input=text.encode("utf-8"),
                    check=True,
                    timeout=5,
                )
                return True
            except subprocess.SubprocessError, OSError:
                pass
        return False

    # Windows
    if platform == "win32":
        if shutil.which("clip"):
            try:
                subprocess.run(
                    ["clip"],
                    input=text.encode("utf-16le"),  # clip.exe expects UTF-16LE
                    check=True,
                    timeout=5,
                )
                return True
            except subprocess.SubprocessError, OSError:
                pass
        return False

    # Linux / other Unix
    # Check for Termux first
    if os.environ.get("TERMUX_VERSION"):
        if shutil.which("termux-clipboard-set"):
            try:
                subprocess.run(
                    ["termux-clipboard-set"],
                    input=text.encode("utf-8"),
                    check=True,
                    timeout=5,
                )
                return True
            except subprocess.SubprocessError, OSError:
                pass

    # Wayland — use spawn (not execSync) to avoid fork deadlock
    if os.environ.get("WAYLAND_DISPLAY"):
        if shutil.which("wl-copy"):
            try:
                proc = subprocess.Popen(
                    ["wl-copy"],
                    stdin=subprocess.PIPE,
                )
                proc.communicate(input=text.encode("utf-8"), timeout=5)
                if proc.returncode == 0:
                    return True
            except subprocess.SubprocessError, OSError:
                pass

    # X11
    if os.environ.get("DISPLAY"):
        for tool in ("xclip", "xsel"):
            if shutil.which(tool):
                try:
                    cmd = (
                        [tool, "-selection", "clipboard"]
                        if tool == "xclip"
                        else [tool, "--clipboard", "--input"]
                    )
                    subprocess.run(
                        cmd,
                        input=text.encode("utf-8"),
                        check=True,
                        timeout=5,
                    )
                    return True
                except subprocess.SubprocessError, OSError:
                    pass

    return False


def copy_to_clipboard(text: str, *, osc52: bool = True) -> bool:
    """Copy text to the system clipboard using the best available method.

    Strategy (matches pi-mono-main's clipboard.ts):
    1. Always emit OSC 52 escape sequence (works over SSH/mosh)
    2. Try native clipboard tool as a bonus (pbcopy, clip, xclip, etc.)

    The OSC 52 escape is always emitted first because it works universally
    in remote sessions. The native tool is a best-effort enhancement.

    Args:
        text: The text to copy to clipboard.
        osc52: Whether to emit the OSC 52 escape (default True).
            Set to False in non-terminal contexts (e.g., tests).

    Returns:
        True if native clipboard was also set, False if only OSC 52 was used.
        Note: OSC 52 success cannot be verified — it's fire-and-forget.
    """
    # 1. Always emit OSC 52 (universal, works over SSH)
    if osc52:
        try:
            osc52_copy(text)
        except OSError, ValueError:
            logger.debug("OSC 52 clipboard failed", exc_info=True)

    # 2. Try native clipboard as bonus
    try:
        return _try_native_clipboard(text)
    except Exception:
        logger.debug("Native clipboard failed", exc_info=True)
        return False
