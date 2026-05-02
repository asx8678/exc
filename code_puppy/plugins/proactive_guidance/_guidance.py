"""Guidance generators for the proactive_guidance plugin.

Extracted from register_callbacks.py to keep the main file under 600 lines.
Each generator reads verbosity from the shared ``_state`` dict injected at
import time by the parent module.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

# -- Shared state (set by register_callbacks at import time) -----------------
_state: dict[str, Any] = {}

# --------------------------------------------------------------------------
# Language-specific guidance map
# --------------------------------------------------------------------------

# Shared guidance for JS/TS/JSX/TSX — they all use the same tooling.
_JS_TS_GUIDANCE: dict[str, str] = {
    "test": "npm test",
    "check": "npx eslint {path}",
    "extra_normal": "npx tsc --noEmit",
    "extra_label": "Type check",
}

_LANG_GUIDANCE: dict[str, dict[str, str]] = {
    ".py": {
        "test": "pytest {path}",
        "check": "python -m py_compile {path}",
        "extra_normal": "mypy {path} (if mypy installed)",
        "extra_label": "Type check",
    },
    ".js": _JS_TS_GUIDANCE,
    ".jsx": _JS_TS_GUIDANCE,
    ".ts": _JS_TS_GUIDANCE,
    ".tsx": _JS_TS_GUIDANCE,
    ".rs": {
        "test": "cargo test",
        "check": "cargo check",
        "extra_normal": "cargo fmt",
        "extra_label": "Format",
    },
    ".go": {
        "test": "go test ./...",
        "check": "go build",
        "extra_normal": "",
        "extra_label": "",
    },
    ".java": {
        "test": "mvn test (if Maven project)",
        "check": "javac {path}",
        "extra_normal": "",
        "extra_label": "",
    },
}

# Structured-data validation per extension (label, command_template)
_STRUCT_VALIDATION: dict[str, tuple[str, str]] = {
    ".json": (
        "✅ Validate",
        "python -c 'import json; json.load(open(\"{path}\"))'",
    ),
    ".yaml": (
        "✅ Validate",
        "python -c 'import yaml; yaml.safe_load(open(\"{path}\"))' (if PyYAML installed)",
    ),
    ".yml": (
        "✅ Validate",
        "python -c 'import yaml; yaml.safe_load(open(\"{path}\"))' (if PyYAML installed)",
    ),
    ".toml": (
        "✅ Validate",
        'python -c \'import tomllib; tomllib.load(open("{path}", "rb"))\'',
    ),
}

# --------------------------------------------------------------------------
# Guidance generators
# --------------------------------------------------------------------------


def _get_write_guidance(
    file_path: str, content_preview: str | None = None
) -> str | None:
    """Generate guidance after write_file tool usage.

    Args:
        file_path: Path to the file that was written
        content_preview: Optional preview of content for context

    Returns:
        Guidance string or None if no guidance applicable
    """
    verbosity = _state.get("verbosity", "normal")
    path = Path(file_path)
    extension = path.suffix.lower()

    suggestions: list[str] = []

    # Language-specific code files
    if extension in _LANG_GUIDANCE:
        lang = _LANG_GUIDANCE[extension]
        suggestions.append(
            f"💡 Run tests: `/shell {lang['test'].format(path=file_path)}`"
        )
        suggestions.append(
            f"🔍 Lint/check: `/shell {lang['check'].format(path=file_path)}`"
        )
        if verbosity != "minimal" and lang.get("extra_normal"):
            suggestions.append(
                f"📝 {lang['extra_label']}: `/shell {lang['extra_normal'].format(path=file_path)}`"
            )

    # Structured data files
    elif extension in _STRUCT_VALIDATION:
        label, cmd_tmpl = _STRUCT_VALIDATION[extension]
        cmd = cmd_tmpl.format(path=file_path)
        suggestions.append(f"{label}: `/shell {cmd}`")

    # Shell scripts
    elif extension in (".sh", ".bash", ".zsh"):
        suggestions.append(
            f"🔐 Check script: `/shell shellcheck {file_path}` (if installed)"
        )
        suggestions.append(f"▶️ Make executable: `/shell chmod +x {file_path}`")

    # Documentation
    elif extension in (".md", ".rst", ".txt"):
        suggestions.append(f"📝 Preview: `/shell head -20 {file_path}`")
        if verbosity != "minimal":
            suggestions.append(f"📊 Word count: `/shell wc -w {file_path}`")

    if verbosity != "minimal" and suggestions:
        suggestions.append(f"📂 View file: `/file {file_path}`")
        suggestions.append("🔎 Search for usages: `/grep pattern directory`")

    if verbosity == "verbose" and suggestions:
        suggestions.append("🧪 Create a test file for this implementation")
        suggestions.append("📊 Check git diff: `/shell git diff --stat`")

    if not suggestions:
        return None

    return "\n".join(["✨ Next steps for your new file:"] + suggestions[:6])


def _get_exploratory_guidance(tool_name: str, tool_args: dict) -> str | None:
    """Generate guidance after exploratory tools (read_file, grep, list_files).

    Only emits at verbose verbosity to reduce noise during normal exploration.

    Args:
        tool_name: The exploratory tool that was used
        tool_args: Arguments passed to the tool

    Returns:
        Guidance string or None
    """
    verbosity = _state.get("verbosity", "normal")
    if verbosity != "verbose":
        return None

    lines = ["📖 Exploratory tool used"]
    lines.append("")
    lines.append("🔍 Next: Use findings to make changes or gather more info")
    lines.append("📝 Consider: read_file on interesting files found")
    lines.append("🎯 Action: Create or modify files based on what you learned")

    return "\n".join(lines)


def _get_shell_guidance(command: str, exit_code: int = 0) -> str | None:
    """Generate guidance after run_shell_command tool usage.

    Args:
        command: The shell command that was executed
        exit_code: Exit code from the command (0 = success)

    Returns:
        Guidance string or None if no guidance applicable
    """
    verbosity = _state.get("verbosity", "normal")
    suggestions = []

    # Parse command to understand context
    cmd_lower = command.lower().strip()

    # Success case
    if exit_code == 0:
        if any(x in cmd_lower for x in ("pytest", "test", "npm test", "cargo test")):
            suggestions.append(
                "✅ Tests passed! Ready to commit? `/git commit -m '...'`"
            )
            if verbosity != "minimal":
                suggestions.append(
                    "📊 Coverage report: `/shell pytest --cov` (if pytest-cov installed)"
                )
        elif any(x in cmd_lower for x in ("git add", "git commit")):
            suggestions.append(
                "🚀 Push changes: `/shell git push origin $(git branch --show-current)`"
            )
            if verbosity == "verbose":
                suggestions.append(
                    "🔄 Or create PR: `/shell gh pr create` (if gh CLI installed)"
                )
        elif any(
            x in cmd_lower for x in ("build", "make", "cargo build", "npm run build")
        ):
            suggestions.append("🎯 Build succeeded! Run it: `/shell ./your_binary`")
            if verbosity != "minimal":
                suggestions.append("📦 Or package: Check your build artifacts")
        elif (
            "pip install" in cmd_lower
            or "npm install" in cmd_lower
            or "cargo add" in cmd_lower
        ):
            suggestions.append(
                "📦 Dependencies updated! Consider locking: `/shell pip freeze > requirements.txt`"
            )
        elif "grep" in cmd_lower or "find" in cmd_lower:
            suggestions.append("🔍 Found matches! Open a file: `/file path/to/file.py`")
        elif "ls" in cmd_lower or "tree" in cmd_lower:
            suggestions.append(
                "📂 Explore further: `/files directory` for detailed listing"
            )

        else:
            suggestions.append("✅ Command completed successfully!")

    # Error case
    else:
        suggestions.append(f"⚠️ Command failed with exit code {exit_code}")
        suggestions.append("🔧 Debug options:")
        suggestions.append("   - Check error output above")
        suggestions.append("   - Run with verbose: Add `-v` or `--verbose` flags")
        suggestions.append("   - Check environment: `/shell env | grep -i <key>`")

    if verbosity != "minimal" and exit_code == 0:
        suggestions.append("📜 Run similar command: Use ↑ or `/shell your_command`")

    return "\n".join(suggestions)


def _get_agent_guidance(
    agent_name: str, result_preview: str | None = None
) -> str | None:
    """Generate guidance after invoke_agent tool usage.

    Args:
        agent_name: Name of the agent that was invoked
        result_preview: Optional preview of agent result

    Returns:
        Guidance string or None if no guidance applicable
    """
    verbosity = _state.get("verbosity", "normal")
    suggestions = []

    suggestions.append(f"🤖 Agent '{agent_name}' completed!")

    if verbosity != "minimal":
        suggestions.append("📋 Review the agent's output above")
        suggestions.append("🔄 Iterate: Make adjustments and re-invoke if needed")

    if verbosity == "verbose":
        suggestions.append("🔍 Compare with parent task context")
        suggestions.append("📝 Document learnings in code comments")

    return "\n".join(suggestions)
