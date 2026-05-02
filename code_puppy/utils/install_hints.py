"""Platform-aware install hints for missing external tools.

When an external tool (ripgrep, fd, jq, etc.) isn't installed, this helper
returns the most appropriate install command for the user's platform,
detecting available package managers in priority order.
"""

import shutil
import sys

# Known tools and their canonical names per package manager
# Format: tool_name -> {package_manager: package_name, ...}
_TOOL_PACKAGES: dict[str, dict[str, str]] = {
    "ripgrep": {
        "brew": "ripgrep",
        "port": "ripgrep",
        "apt-get": "ripgrep",
        "dnf": "ripgrep",
        "yum": "ripgrep",
        "pacman": "ripgrep",
        "zypper": "ripgrep",
        "apk": "ripgrep",
        "choco": "ripgrep",
        "scoop": "ripgrep",
        "winget": "BurntSushi.ripgrep.MSVC",
        "cargo": "ripgrep",
    },
    "fd": {
        "brew": "fd",
        "apt-get": "fd-find",  # Debian-specific name
        "dnf": "fd-find",
        "pacman": "fd",
        "choco": "fd",
        "cargo": "fd-find",
    },
    "jq": {
        "brew": "jq",
        "port": "jq",
        "apt-get": "jq",
        "dnf": "jq",
        "pacman": "jq",
        "choco": "jq",
        "scoop": "jq",
        "winget": "stedolan.jq",
    },
    # Add more as needed — agents may suggest additions
}

_FALLBACK_URLS: dict[str, str] = {
    "ripgrep": "https://github.com/BurntSushi/ripgrep#installation",
    "fd": "https://github.com/sharkdp/fd#installation",
    "jq": "https://stedolan.github.io/jq/download/",
}


def install_hint(tool_name: str) -> str:
    """Return a platform-aware install command for a tool, or a fallback URL.

    >>> # On macOS with brew installed:
    >>> install_hint("ripgrep")
    'brew install ripgrep'
    >>> # On Ubuntu:
    >>> install_hint("ripgrep")
    'sudo apt-get install ripgrep'
    """
    packages = _TOOL_PACKAGES.get(tool_name, {})
    plat = sys.platform

    # Priority order per platform
    if plat == "darwin":
        priority = ["brew", "port", "cargo"]
    elif plat == "linux":
        priority = ["apt-get", "dnf", "yum", "pacman", "zypper", "apk", "cargo"]
    elif plat == "win32":
        priority = ["winget", "choco", "scoop", "cargo"]
    else:
        priority = ["cargo"]  # BSDs, etc

    for pm in priority:
        if pm not in packages:
            continue
        if shutil.which(pm) is None:
            continue
        pkg = packages[pm]
        if pm in {"apt-get", "dnf", "yum", "zypper", "apk"}:
            return f"sudo {pm} install {pkg}"
        return f"{pm} install {pkg}"

    # Unknown tool or no package manager detected
    return _FALLBACK_URLS.get(tool_name, f"Install {tool_name} manually")


def format_missing_tool_message(tool_name: str, *, context: str | None = None) -> str:
    """Format a full error message for a missing tool, including install hint."""
    hint = install_hint(tool_name)
    parts = [f"⚠️ `{tool_name}` is not installed."]
    if context:
        parts.append(f"({context})")
    parts.append(f"Install it with: {hint}")
    return " ".join(parts)
