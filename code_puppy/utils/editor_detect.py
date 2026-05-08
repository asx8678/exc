"""Editor detection with PATH probing.

Ported from plandex/app/cli/lib/editor.go detectEditors(). Probes ~25
known editor commands on PATH, honors $VISUAL / $EDITOR env vars, and
collapses per-IDE JetBrains launchers when the universal ``jb`` launcher
is installed.

Usage:
    candidates = detect_editors()          # list of EditorCandidate, max 5
    default = pick_default_editor()         # best single choice or None
"""

import os
import shutil
from dataclasses import dataclass
from pathlib import Path

MAX_EDITOR_OPTS = 5


@dataclass(frozen=True)
class EditorCandidate:
    """A single editor launcher that exists on the current PATH."""

    name: str
    command: str
    args: tuple[str, ...] = ()
    is_jetbrains: bool = False


# Editor probe table — order matters for display priority when nothing is preferred.
# Mirrors plandex/app/cli/lib/editor.go detectEditors()'s candidate list.
_CANDIDATE_TABLE: tuple[EditorCandidate, ...] = (
    # Popular GUI editors
    EditorCandidate("VS Code", "code"),
    EditorCandidate("Cursor", "cursor"),
    EditorCandidate("Zed", "zed"),
    EditorCandidate("Neovim", "nvim"),
    # JetBrains IDE-specific launchers
    EditorCandidate("IntelliJ IDEA", "idea", is_jetbrains=True),
    EditorCandidate("GoLand", "goland", is_jetbrains=True),
    EditorCandidate("PyCharm", "pycharm", is_jetbrains=True),
    EditorCandidate("CLion", "clion", is_jetbrains=True),
    EditorCandidate("WebStorm", "webstorm", is_jetbrains=True),
    EditorCandidate("PhpStorm", "phpstorm", is_jetbrains=True),
    EditorCandidate("DataGrip", "datagrip", is_jetbrains=True),
    EditorCandidate("RubyMine", "rubymine", is_jetbrains=True),
    EditorCandidate("Rider", "rider", is_jetbrains=True),
    EditorCandidate("DataSpell", "dataspell", is_jetbrains=True),
    # JetBrains universal CLI (2023.2+)
    EditorCandidate("JetBrains (jb)", "jb", args=("open",), is_jetbrains=True),
    # Traditional terminal editors
    EditorCandidate("Vim", "vim"),
    EditorCandidate("Nano", "nano"),
    EditorCandidate("Helix", "hx"),
    EditorCandidate("Micro", "micro"),
    EditorCandidate("Sublime Text", "subl"),
    EditorCandidate("TextMate", "mate"),
    EditorCandidate("Kakoune", "kak"),
    EditorCandidate("Emacs", "emacs"),
    EditorCandidate("Kate", "kate"),
)


def _preferred_commands_from_env() -> set[str]:
    """Return the base command names mentioned in $VISUAL and $EDITOR env vars."""
    prefs: set[str] = set()
    for var in ("VISUAL", "EDITOR"):
        value = os.environ.get(var, "").strip()
        if not value:
            continue
        # Extract base name of the first token; drop any path or flags
        first = value.split()[0]
        prefs.add(Path(first).name)
    return prefs


def _which(cmd: str) -> str | None:
    """Thin wrapper around shutil.which for easier test monkeypatching."""
    return shutil.which(cmd)


def detect_editors() -> list[EditorCandidate]:
    """Return the list of editor candidates present on the PATH, max ``MAX_EDITOR_OPTS``.

    Ordering:
    1. Editors named in $VISUAL / $EDITOR come first (stable).
    2. Remaining editors follow in the static table order.
    3. If the JetBrains universal launcher (`jb`) is on PATH, per-IDE
       JetBrains launchers are dropped unless explicitly preferred via env.
    4. Custom commands from $VISUAL/$EDITOR that aren't in the static
       table are appended if the command is on PATH.
    5. Final list capped at MAX_EDITOR_OPTS.
    """
    preferred = _preferred_commands_from_env()
    jb_on_path = _which("jb") is not None

    found: list[EditorCandidate] = []
    for candidate in _CANDIDATE_TABLE:
        if _which(candidate.command) is None:
            continue
        # If jb is present, drop per-IDE JetBrains launchers (except if preferred)
        if jb_on_path and candidate.is_jetbrains and candidate.command != "jb":
            if candidate.command not in preferred:
                continue
        found.append(candidate)

    # Add any preferred command that wasn't already in the table
    existing_cmds = {c.command for c in found}
    for cmd in preferred:
        if cmd not in existing_cmds and _which(cmd) is not None:
            found.append(EditorCandidate(name=cmd, command=cmd))
            existing_cmds.add(cmd)

    # Stable sort: preferred editors first
    def _priority_key(c: EditorCandidate) -> int:
        return 0 if c.command in preferred else 1

    found.sort(key=_priority_key)

    return found[:MAX_EDITOR_OPTS]


def pick_default_editor() -> EditorCandidate | None:
    """Return the single best editor to open by default.

    Priority: first item of :func:`detect_editors`. Returns None on failure.
    Falls back to ``nano`` (Unix) or ``notepad`` (Windows) as a last resort
    if those happen to be on PATH.
    """
    candidates = detect_editors()
    if candidates:
        return candidates[0]
    # Absolute fallback
    for cmd, name in (("nano", "Nano"), ("notepad", "Notepad")):
        if _which(cmd) is not None:
            return EditorCandidate(name=name, command=cmd)
    return None
