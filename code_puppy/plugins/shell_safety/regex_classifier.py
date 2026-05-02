"""Regex-based pre-filter for shell command safety classification.

This module provides fast, deterministic command classification using regex
patterns to catch obvious attacks instantly. It implements a two-pass
classification strategy:

1. Whole-command scan for high-risk patterns (fork bombs, rm -rf /, etc.)
2. Per-subcommand scan after splitting compound commands

Design principles:
- Fail-closed: Unclosed quotes or parse errors result in blocking
- Quote-aware: Patterns inside quotes don't trigger false positives
- Fast path: Returns immediately for safe commands without LLM roundtrip
- Defense in depth: Regex blocks obvious attacks; LLM handles edge cases

SECURITY FIXES (issue code_puppy-70t):
- Regex patterns use bounded repetition to prevent O(n²) catastrophic backtracking
- Added 600-line and 10000-char limits to prevent DoS via regex matching
- Added explicit find -delete/-exec patterns for mass deletion detection
- CRITICAL FIX: Shared sensitive path patterns prevent shell bypasses
- CRITICAL FIX: Path normalization in _normalize_command_for_checks()
  collapses multiple slashes (//+ -> /) and removes dot segments (/./ -> /)
  to prevent bypasses like //etc/passwd or /./etc/passwd
"""

import re
from dataclasses import dataclass
from typing import Literal

# SECURITY FIX: Import shared sensitive path patterns from central module.
# This ensures shell command filtering blocks ALL paths that file_operations
# blocks, preventing bypass vectors where shell commands read sensitive files.
from code_puppy.sensitive_paths import (
    SENSITIVE_PATH_REGEX_PATTERN,
)

# SECURITY: Maximum command length to prevent regex DoS
# Commands longer than this are rejected immediately
MAX_COMMAND_LENGTH = 10000  # ~600 lines of average 16 chars each
MAX_COMMAND_LINES = 600


@dataclass
class RegexClassificationResult:
    """Result of regex-based command classification.

    Attributes:
        risk: Classification result - 'critical', 'high', 'medium', 'low', 'none',
              or 'ambiguous' when regex can't determine (needs LLM)
        reasoning: Explanation for the classification
        blocked: True if command should be blocked immediately
        is_ambiguous: True if LLM assessment is needed
    """

    risk: Literal["critical", "high", "medium", "low", "none", "ambiguous"]
    reasoning: str
    blocked: bool = False
    is_ambiguous: bool = False


# =============================================================================
# High-risk patterns that warrant immediate blocking
# =============================================================================

# Pre-compiled patterns for whole-command scan (fork bombs, download-pipe)
# These are defined at module level to avoid recompilation on every call
# SECURITY FIX: All patterns use atomic/possessive-like optimizations to prevent
# catastrophic backtracking (O(n²) performance on crafted input)
_WHOLE_COMMAND_DANGEROUS: list[tuple[re.Pattern, str]] = [
    # Fork bombs - various forms (dangerous even quoted)
    # OPTIMIZED: Using atomic-like character class patterns instead of [^}]*
    (
        re.compile(r":\s*\(\s*\)\s*\{[^{}]*:\s*\|[^{}]*&[^{}]*\}"),
        "fork bomb (bash function form)",
    ),
    (
        re.compile(r"\bbash\s+-c\s+['\"]?:\(\)\s*\{[^{}]*:\s*\|[^{}]*&"),
        "fork bomb via bash -c",
    ),
    (
        re.compile(r"\bsh\s+-c\s+['\"]?:\(\)\s*\{[^{}]*:\s*\|[^{}]*&"),
        "fork bomb via sh -c",
    ),
    # Download and execute patterns (highly dangerous even quoted)
    # OPTIMIZED: Using non-greedy matching and line-bound for safety
    (
        re.compile(
            r"\b(?:curl|wget|fetch|lynx|aria2c)(?:\s+[^|&;\r\n]{0,500})?[|&;]\s*"
            r"(?:\bsh\b|\bbash\b|\bzsh\b|\bksh\b|\bpython\d*\b|\bperl\b|\bruby\b|\bnode\b|\bcat(?:\s+[^|&;\r\n]{0,100})?\|?\s*sh\b)"
        ),
        "download piped to shell interpreter",
    ),
    (
        re.compile(
            r"\b(?:curl|wget)(?:\s+[^\r\n]{0,500})?\|\s*"
            r"(?:eval|exec|source|\.)\b"
        ),
        "download piped to eval/exec/source",
    ),
]

_HIGH_RISK_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Fork bombs - various forms (additional patterns beyond whole-command scan)
    # OPTIMIZED: Using bounded repetition and non-greedy matching
    (
        re.compile(r":\s*\(\s*\)\s*\{[^{}]*:\s*\|[^{}]*&[^{}]*\}"),
        "fork bomb (bash function form)",
    ),
    (
        re.compile(r"\bbash\s+-c\s+['\"]?:\(\)\s*\{[^{}]*:\s*\|[^{}]*&"),
        "fork bomb via bash -c",
    ),
    (
        re.compile(r"\bsh\s+-c\s+['\"]?:\(\)\s*\{[^{}]*:\s*\|[^{}]*&"),
        "fork bomb via sh -c",
    ),
    # Classic fork bomb in variable form - OPTIMIZED
    (
        re.compile(r"\b[a-zA-Z_]\w*\s*=\s*\(\s*\)\s*\{[^{}]{0,200}\|\s*\$[a-zA-Z_]\w*"),
        "fork bomb (variable assignment form)",
    ),
    # SECURITY FIX: rm -rf / and variants - hardened to handle more bypasses
    # The pattern requires standalone "/" (end of string, whitespace, or another /)
    # This does NOT match "/tmp/build" because the "/" is followed by a word char
    # Now handles: -- separator, quoted paths, root-equivalent paths (/., //, ///)
    (
        re.compile(
            r"\brm\b"
            r"(?:\s+(?:-[a-zA-Z]*[rf][a-zA-Z]*|--force|--recursive|--preserve-root))*"
            r"(?:\s+--)?"  # Optional -- separator
            r"\s+(?:--no-preserve-root|['\"]?(?:/|/\.?|/+/|/\*|/\*/?)(?:\s|$|['\"]))"
        ),
        "rm recursive force delete of root",
    ),
    (
        re.compile(
            r"\brm\b(?:\s+(?:-[a-zA-Z]*[rf][a-zA-Z]*|(?:--force|--recursive)))+\s+--no-preserve-root"
        ),
        "rm force delete with no-preserve-root",
    ),
    # Also match explicit rm -r / or rm -f / followed by additional flags (at root only)
    # SECURITY FIX: Handles quoted root paths like '/' or "/"
    (
        re.compile(
            r"\brm\s+(?:-[a-zA-Z]*r[a-zA-Z]*\s+)+(?:-[a-zA-Z]*f[a-zA-Z]*\s+)*['\"]?/(?:\s|$|['\"])"
        ),
        "rm recursive delete of root",
    ),
    # SECURITY FIX: Handle rm -rf -- / with -- separator explicitly
    (
        re.compile(
            r"\brm\b(?:\s+-(?:[a-zA-Z]*[rf][a-zA-Z]*))+\s+--\s+['\"]?/?(?:\s|$|['\"])"
        ),
        "rm with -- separator targeting root",
    ),
    # Disk destruction
    (
        re.compile(
            r"\bdd\s+(?:[^\r\n]{0,300})?\bif\s*=\s*\S*(?:/dev/zero|/dev/urandom|/dev/random)\b"
            r"(?:[^\r\n]{0,300})?\bof\s*=\s*\S*(?:/dev/[sh]d[a-z]|/dev/nvme\d+n\d+|/dev/disk\d+)"
        ),
        "disk overwrite with random/zero data",
    ),
    (
        re.compile(
            r"\bdd\s+(?:[^\r\n]{0,300})?\bof\s*=\s*\S*(?:/dev/[sh]d[a-z]|/dev/nvme\d+n\d+|/dev/disk\d+|/dev/mmcblk\d+)"
        ),
        "direct disk write",
    ),
    (
        re.compile(
            r"\bmkfs\.?(?:ext[234]|xfs|btrfs|zfs|fat|ntfs|vfat|exfat)\s+\S*"
            r"(?:/dev/[sh]d[a-z]\d*|/dev/nvme\d+n\d+(?:p\d+)?|/dev/mmcblk\d+p?\d*)"
        ),
        "filesystem creation on raw device",
    ),
    (
        re.compile(r"\bformat\s+(?:[^\r\n]{0,200})?(?:/dev/[sh]d|\\\\.*PhysicalDrive)"),
        "disk format operation",
    ),
    # Download and execute patterns (highly dangerous)
    # OPTIMIZED: Bounded repetition to prevent O(n²) backtracking
    (
        re.compile(
            r"\b(?:curl|wget|fetch|lynx|aria2c)(?:\s+[^|&;\r\n]{0,500})?[|&;]\s*"
            r"(?:\bsh\b|\bbash\b|\bzsh\b|\bksh\b|\bpython\d*\b|\bperl\b|\bruby\b|\bnode\b|\bcat(?:\s+[^|&;\r\n]{0,100})?\|?\s*sh\b)"
        ),
        "download piped to shell interpreter",
    ),
    (
        re.compile(
            r"\b(?:curl|wget)(?:\s+[^\r\n]{0,500})?\|\s*(?:eval|exec|source|\.)\b"
        ),
        "download piped to eval/exec/source",
    ),
    # Command substitution attacks - OPTIMIZED: non-greedy matching
    (
        re.compile(r"\$\([^\)]{0,200}(?:rm|mkfs|dd|format|del|erase)[^\)]{0,200}\)"),
        "dangerous command substitution",
    ),
    (
        re.compile(r"`[^`]{0,200}(?:rm|mkfs|dd|format|del|erase)[^`]{0,200}`"),
        "dangerous backtick substitution",
    ),
    # Privilege escalation with dangerous ops
    (
        re.compile(r"\bsudo\s+(?:[^\r\n]{0,300})?\brm\s+-rf\b"),
        "sudo recursive force delete",
    ),
    (
        re.compile(r"\bsudo\s+(?:[^\r\n]{0,300})?\bdd\s+(?:[^\r\n]{0,200})?of=/dev"),
        "sudo direct disk write",
    ),
    # Database destruction
    (
        re.compile(
            r"\bmysql\s+(?:[^\r\n]{0,200})?(?:--execute|-e)\s+['\"]?"
            r"(?:DROP\s+DATABASE|DROP\s+TABLE|TRUNCATE\s+TABLE)"
        ),
        "MySQL destructive operation",
    ),
    (
        re.compile(
            r"\bpsql\s+(?:[^\r\n]{0,200})?(?:-c\s+['\"]?)?(?:DROP\s+DATABASE|DROP\s+TABLE|TRUNCATE\s+TABLE)"
        ),
        "PostgreSQL destructive operation",
    ),
    (
        re.compile(
            r"\bsqlite3?(?:\s+[^\r\n]{0,200})?(?:;\s*)?(?:DROP\s+TABLE|DELETE\s+FROM\s+\w+\s*(?!WHERE))"
        ),
        "SQLite destructive operation without WHERE clause",
    ),
    # Windows-specific dangerous commands
    (
        re.compile(r"\brd\s+/[sq]\s+(?:[^\r\n]{0,200})?[\\/]", re.IGNORECASE),
        "Windows recursive directory delete",
    ),
    (
        re.compile(r"\bdel\s+/[fq]\s+(?:[^\r\n]{0,200})?\\\*\.", re.IGNORECASE),
        "Windows mass file delete",
    ),
    (re.compile(r"\bformat\s+[a-z]:\s+/[fqy]", re.IGNORECASE), "Windows drive format"),
    (
        re.compile(r"\bdiskpart(?:\s+[^\r\n]{0,200})?clean\b", re.IGNORECASE),
        "Windows diskpart clean",
    ),
    # Malicious encodings/obfuscation
    (
        re.compile(
            r"\b(?:eval|exec)\s*\$?\([^\)]{0,200}base64[^\)]{0,200}\)", re.IGNORECASE
        ),
        "eval of base64 decoded content",
    ),
    (
        re.compile(
            r"\becho\s+['\"]?[A-Za-z0-9+/]{50,}={0,2}['\"]?\s*\|\s*(?:base64|openssl)\s+-d"
        ),
        "base64 decode of suspicious payload",
    ),
    # Kernel/module manipulation
    (re.compile(r"\binsmod\s+\S+\.ko\b"), "kernel module insertion"),
    (re.compile(r"\brmmod\s+\S+"), "kernel module removal"),
    (re.compile(r"\bmodprobe\s+-r\b"), "kernel module removal"),
    # SECURITY FIX: find -delete patterns (mass deletion vulnerability)
    # find / with -delete is extremely dangerous - can delete entire filesystem
    # OPTIMIZED: Fixed path patterns - ~/.* instead of ~/\.*, removed . (current dir is less dangerous)
    # SECURITY FIX: Now handles quoted root paths like '/' or "/"
    (
        re.compile(
            r"\bfind\s+(?:['\"]?/['\"]?|/\.\*|/\*|/\.?\.|~/.+|~)\s+(?:[^\r\n]{0,400})?-delete\b"
        ),
        "find with -delete targeting root/home directory",
    ),
    (
        re.compile(
            r"\bfind\s+(?:['\"]?/['\"]?|/\.\*|/\*|/\.?\.|~/.+|~)\s+(?:[^\r\n]{0,400})?-exec\s+rm\s+(?:-[rf]+\s+)?(?:\{\}|/|\*)"
        ),
        "find -exec rm targeting root/home directory",
    ),
    (
        re.compile(
            r"\bfind\s+(?:['\"]?/['\"]?|/\.\*|/\*|/\.?\.|~/.+|~)\s+(?:[^\r\n]{0,400})?-execdir\s+rm\b"
        ),
        "find -execdir rm targeting root/home directory",
    ),
    # Fallback pattern for root-only detection (catches cases above might miss)
    # SECURITY FIX: Now handles quoted paths like find '/' -delete
    (
        re.compile(r"\bfind\s+['\"]?/['\"]?\s+-delete\b"),
        "find -delete at filesystem root",
    ),
]

# =============================================================================
# Medium-risk patterns that warrant caution but not immediate blocking
# =============================================================================

_MEDIUM_RISK_PATTERNS: list[tuple[re.Pattern, str]] = [
    # rm without -rf but targeting system paths
    # Note: \b before /etc is dead code (word boundary doesn't match before /)
    # We use negative lookbehind to ensure it's a start of path
    (
        re.compile(r"\brm\s+.*(?:^|\s)(?:/etc|/bin|/sbin|/lib|/usr|/var|/home)/"),
        "deletion in system directory",
    ),
    (re.compile(r"\brm\s+.*\b\.\./.*\.\."), "deletion with parent directory traversal"),
    # chmod/chown with dangerous permissions
    (
        re.compile(r"\bchmod\s+(?:777|666|755)\s+.*\b(?:/etc|/bin|/usr|/var)"),
        "broad permissions on system files",
    ),
    (
        re.compile(r"\bchown\s+-R\s+root:root\s+.*\b(?:/home|/tmp|/var)"),
        "recursive root ownership change",
    ),
    # Network operations to suspicious destinations
    (
        re.compile(
            r"\b(?:curl|wget|fetch)\s+.*\b(?:pastebin|hastebin|ghostbin|termbin)\b"
        ),
        "download from text sharing service",
    ),
    (
        re.compile(
            r"\b(?:curl|wget|fetch)\s+.*\b(?:0x[0-9a-f]{8,}|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"
        ),
        "download from hex-encoded or raw IP",
    ),
    # Sudo operations (not already covered by high-risk)
    (
        re.compile(r"\bsudo\s+.*\b(?:chmod|chown|chgrp)\s+-R\b"),
        "recursive permission change with sudo",
    ),
    # Environment manipulation
    (
        re.compile(r"\bexport\s+PATH=[^:]*:?(?:/tmp|/var/tmp|/dev/shm)\b"),
        "PATH manipulation with temp directories",
    ),
]

# =============================================================================
# Low-risk patterns that are generally safe but worth noting
# =============================================================================

_LOW_RISK_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Package managers (moderate concern)
    (
        re.compile(
            r"\b(?:apt|yum|dnf|pacman|brew|pip|npm|gem)\s+(?:install|remove|uninstall|purge)\b"
        ),
        "package installation/removal",
    ),
    # Service operations
    (
        re.compile(r"\b(?:systemctl|service)\s+(?:stop|restart|disable|kill)\b"),
        "service control operation",
    ),
    # User management
    (
        re.compile(r"\b(?:useradd|userdel|groupadd|groupdel|usermod)\b"),
        "user/group modification",
    ),
]

# =============================================================================
# Safe patterns - commands that are obviously harmless
# =============================================================================

_SAFE_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Basic file listing and navigation
    (
        re.compile(r"^\s*(?:ls|ll|la|dir)\s*(?:-[a-zA-Z]+\s*)*(?:[~/\.\w-]*)\s*$"),
        "file listing",
    ),
    (re.compile(r"^\s*pwd\s*$"), "print working directory"),
    (re.compile(r"^\s*cd\s+[~\./\w-]*\s*$"), "change directory"),
    # Git operations (read-only)
    (
        re.compile(
            r"^\s*git\s+(?:status|log|show|diff|branch|remote|config\s+--list)\b"
        ),
        "git read operation",
    ),
    # Process listing
    (re.compile(r"^\s*(?:ps|top|htop|pgrep)\b"), "process listing"),
    # Help and version
    (
        re.compile(r"^\s*(?:\w+)\s+(?:--help|--version|-h|-v)\s*$"),
        "help/version display",
    ),
]


def _split_compound_command(command: str) -> tuple[list[str], bool]:
    """Split compound shell command into individual sub-commands.

    Uses quote-aware tokenization. Returns (sub_commands, parse_ok).
    If parse_ok is False, the command had unclosed quotes and should be blocked.

    Args:
        command: Shell command string to split.

    Returns:
        Tuple of (list of sub-commands, bool indicating if parsing succeeded).
    """
    parts: list[str] = []
    current: list[str] = []
    i = 0
    in_single_quote = False
    in_double_quote = False

    while i < len(command):
        c = command[i]

        if in_single_quote:
            if c == "'":
                in_single_quote = False
            current.append(c)

        elif in_double_quote:
            if c == "\\" and i + 1 < len(command):
                # Escaped char in double quotes
                current.append(c)
                current.append(command[i + 1])
                i += 2
                continue
            if c == '"':
                in_double_quote = False
            current.append(c)

        else:
            if c == "'":
                in_single_quote = True
                current.append(c)
            elif c == '"':
                in_double_quote = True
                current.append(c)
            elif c in ("&", "|") and i + 1 < len(command) and command[i + 1] == c:
                # Compound operator && or ||
                part = "".join(current).strip()
                if part:
                    parts.append(part)
                current = []
                i += 2
                continue
            elif c == ";":
                # Command separator
                part = "".join(current).strip()
                if part:
                    parts.append(part)
                current = []
            else:
                current.append(c)

        i += 1

    # Check for unclosed quotes - fail closed
    if in_single_quote or in_double_quote:
        return parts, False

    # Add final part
    last = "".join(current).strip()
    if last:
        parts.append(last)

    return parts if parts else [command.strip()], True


def _extract_unquoted_text(command: str) -> str:
    """Extract text that is outside of quoted strings.

    This helps avoid false positives when dangerous patterns appear
    inside quoted arguments to safe commands like echo.

    Args:
        command: Shell command string.

    Returns:
        Text with quoted portions removed (replaced with spaces).
    """
    result: list[str] = []
    i = 0
    in_single_quote = False
    in_double_quote = False

    while i < len(command):
        c = command[i]

        if in_single_quote:
            if c == "'":
                in_single_quote = False
                result.append(" ")  # Replace quote content with space
            # Skip everything inside single quotes
            pass

        elif in_double_quote:
            if c == "\\" and i + 1 < len(command):
                # Skip escaped char
                i += 2
                continue
            if c == '"':
                in_double_quote = False
                result.append(" ")  # Replace quote content with space
            # Skip everything inside double quotes
            pass

        else:
            if c == "'":
                in_single_quote = True
                result.append(" ")
            elif c == '"':
                in_double_quote = True
                result.append(" ")
            else:
                result.append(c)

        i += 1

    return "".join(result)


# Pre-compiled patterns for checking sensitive paths in file operations
# SECURITY FIX: Now using shared patterns from code_puppy.security.sensitive_paths
# This ensures shell command filtering blocks ALL paths that file_operations blocks.
# Added paths: /private/etc (macOS), /dev (device files), ~root (root home via tilde)
#
# Old pattern (for reference):
# (?:^|\s|<<?<?)(?:/etc|/root|/proc|~/.ssh|~/.aws|/var/log|/home/root)(?:/|$|\s)
#
# Using shared pattern to prevent bypass vectors where shell commands read
# sensitive files that file_operations correctly blocks.
_SENSITIVE_PATH_PATTERN = SENSITIVE_PATH_REGEX_PATTERN

# SECURITY FIX: Pattern to detect relative path traversal that could escape to sensitive paths
_TRAVERSAL_PATTERN = re.compile(r"\.\./")


def _strip_quotes(path: str) -> str:
    """Strip surrounding quotes from a path string.

    Handles both single and double quotes. Used for normalizing paths
    before security checks.

    Args:
        path: Path string that may be quoted.

    Returns:
        Path with surrounding quotes removed.

    Examples:
        >>> _strip_quotes("'/etc/shadow'")
        '/etc/shadow'
        >>> _strip_quotes('/etc/shadow')
        '/etc/shadow'
    """
    path = path.strip()
    if len(path) >= 2:
        if path[0] == path[-1] and path[0] in ('"', "'"):
            return path[1:-1]
    return path


def _normalize_path(path: str) -> str:
    """Normalize a path by stripping quotes and expanding leading ~.

    Args:
        path: Path string to normalize.

    Returns:
        Normalized path.
    """
    path = _strip_quotes(path)
    # Expand ~ at the start (for home directory references)
    if path.startswith("~/"):
        # Keep as ~/ for pattern matching purposes
        pass
    return path


def _normalize_command_for_checks(command: str) -> str:
    """Normalize command string for security checks.

    Strips quotes from paths within the command so that sensitive
    path detection works on quoted arguments like '/etc/shadow'.
    Also normalizes path separators to prevent bypass attempts
    like //etc/passwd or /./etc/passwd.

    Args:
        command: Shell command string.

    Returns:
        Command with quoted paths normalized (quotes stripped) and
        path separators collapsed (//+ -> /, /./ -> /).
    """
    # Extract all quoted strings and unquote them
    result = command
    # Pattern to match quoted strings
    quoted_pattern = re.compile(r"([\"'])([^\"']*?)\1")

    def unquote_match(match: re.Match) -> str:
        # Return the content without quotes
        return match.group(2)

    result = quoted_pattern.sub(unquote_match, result)

    # SECURITY FIX: Normalize path separators to prevent bypass
    # Collapse multiple slashes: //etc -> /etc, ///etc -> /etc
    result = re.sub(r"/{2,}", "/", result)

    # Remove /. segments: /./etc -> /etc, /foo/./bar -> /foo/bar
    # But preserve standalone . and ..
    result = re.sub(r"/\.(?=/|$)", "", result)

    return result


def _path_with_traversal_hits_sensitive(command: str) -> bool:
    """Check if a command with path traversal could access sensitive paths.

    Detects patterns like ../../../etc/shadow that escape the repo and
    target sensitive system paths.

    Args:
        command: Normalized command string to check.

    Returns:
        True if traversal pattern could hit sensitive paths.
    """
    # Extract all path-like tokens from the command
    # Look for patterns ending with sensitive path fragments
    sensitive_fragments = [
        "/etc",
        "/root",
        "/proc",
        ".ssh",
        ".aws",
        "/var/log",
        "/home/root",
        "/bin",
        "/sbin",
        "/usr",
        "/dev",
    ]

    # Check if any sensitive fragment appears after or within traversal
    if "../" in command:
        for fragment in sensitive_fragments:
            if fragment in command:
                return True
    return False


# Pre-compiled patterns for checking redirects and command substitution
# SECURITY FIX: Now includes input redirection (<, <<, <<<) to prevent bypasses
_REDIRECT_PATTERN = re.compile(r"[<>>>]\s?|<<\s?|<<<\s?|\||\x60.*\x60|\$\(")


def _classify_single_command(command: str) -> RegexClassificationResult:
    """Classify a single (non-compound) command using regex patterns.

    Checks patterns in order of severity: high-risk first, then medium,
    then low, then safe. Returns at first match.

    For high-risk patterns, we check both the raw command and the
    unquoted version (to avoid false positives from quoted strings).

    Args:
        command: Single shell command (no &&, ||, or ; operators).

    Returns:
        RegexClassificationResult with risk level and reasoning.
    """
    # Get unquoted version for safer pattern matching
    unquoted = _extract_unquoted_text(command)

    # Check high-risk patterns first (immediate blocking)
    # We check both raw and unquoted - some patterns (fork bombs, pipes)
    # are dangerous even quoted, others we check only unquoted
    # SECURITY FIX: Get normalized command (quotes stripped, not replaced with spaces)
    normalized_cmd = _normalize_command_for_checks(command)

    for pattern, description in _HIGH_RISK_PATTERNS:
        # SECURITY FIX: Different check strategies for different pattern types:
        # - rm patterns: check normalized (strips quotes, catches rm '/')
        # - find patterns: check BOTH raw (for quoted paths) AND normalized
        # - other patterns (fork bombs, pipes): check raw command
        if "find" in description:
            # Check raw command for quoted path support (find '/', etc.)
            if pattern.search(command):
                return RegexClassificationResult(
                    risk="critical",
                    reasoning=f"High-risk pattern detected: {description}",
                    blocked=True,
                    is_ambiguous=False,
                )
            # Also check normalized (unquoted but preserving path structure)
            if pattern.search(normalized_cmd):
                return RegexClassificationResult(
                    risk="critical",
                    reasoning=f"High-risk pattern detected: {description}",
                    blocked=True,
                    is_ambiguous=False,
                )
        elif any(
            x in description
            for x in ["delete", "disk", "filesystem", "format", "recursive"]
        ):
            # SECURITY FIX: Check unquoted first to avoid false positives
            if pattern.search(unquoted):
                return RegexClassificationResult(
                    risk="critical",
                    reasoning=f"High-risk pattern detected: {description}",
                    blocked=True,
                    is_ambiguous=False,
                )
            # Also check normalized ONLY if command starts with destructive verb
            # This catches rm -rf '/' but avoids false positives from echo "rm -rf /"
            starts_with_destructive = re.match(
                r"^\s*(?:rm\b|dd\b|mkfs|format\b|del\b|rd\b)", normalized_cmd
            )
            if starts_with_destructive and pattern.search(normalized_cmd):
                return RegexClassificationResult(
                    risk="critical",
                    reasoning=f"High-risk pattern detected: {description}",
                    blocked=True,
                    is_ambiguous=False,
                )
        else:
            # For other patterns (fork bombs, pipes), check raw command
            if pattern.search(command):
                return RegexClassificationResult(
                    risk="critical",
                    reasoning=f"High-risk pattern detected: {description}",
                    blocked=True,
                    is_ambiguous=False,
                )

    # Check medium-risk patterns
    # SECURITY FIX: Use unquoted text to avoid false positives in quoted strings
    # like: echo "sudo chmod -R /tmp" (just an example string, not a command)
    for pattern, description in _MEDIUM_RISK_PATTERNS:
        if pattern.search(unquoted):
            return RegexClassificationResult(
                risk="medium",
                reasoning=f"Medium-risk pattern detected: {description}",
                blocked=False,
                is_ambiguous=True,  # Needs LLM for final decision
            )

    # Check low-risk patterns
    # SECURITY FIX: Use unquoted text to avoid false positives
    for pattern, description in _LOW_RISK_PATTERNS:
        if pattern.search(unquoted):
            return RegexClassificationResult(
                risk="low",
                reasoning=f"Low-risk pattern detected: {description}",
                blocked=False,
                is_ambiguous=True,  # Needs LLM for final decision
            )

    # Check safe patterns (return quickly) - be more permissive for safe commands
    # First check exact patterns
    for pattern, description in _SAFE_PATTERNS:
        if pattern.match(command):
            return RegexClassificationResult(
                risk="none",
                reasoning=f"Safe pattern detected: {description}",
                blocked=False,
                is_ambiguous=False,
            )

    # Additional heuristics for safe commands that didn't match exact patterns
    # SECURITY FIX: Heuristics are now stricter to avoid false negatives
    # These are common read-only operations with restrictions on sensitive paths

    # Check git operations (always safe)
    if re.match(
        r"^\s*git\s+(?:status|log|show|diff|branch|remote|config|stash\s+list|tag)\b",
        command,
    ):
        return RegexClassificationResult(
            risk="none",
            reasoning="Safe pattern detected: git read operation",
            blocked=False,
            is_ambiguous=False,
        )

    # Check file listing (always safe)
    if re.match(r"^\s*(?:ls|ll|la|dir)\b", command):
        return RegexClassificationResult(
            risk="none",
            reasoning="Safe pattern detected: file listing",
            blocked=False,
            is_ambiguous=False,
        )

    # Check file reading (EXCLUDES sensitive paths)
    # First check if it matches the pattern, then verify no sensitive paths
    # SECURITY FIX: Also check for input redirects (<) that could access sensitive files
    file_read_match = re.match(
        r"^\s*(?:cat|head|tail|less|more)\s+(?:-[a-zA-Z0-9]+\s+)*[^|;\&\`\$>]*$",
        command,
    )
    # Also allow input redirection form: cat < /path/to/file or cat </path/to/file
    # SECURITY FIX: Pattern handles both spaced (cat < /file) and non-spaced (cat </file) variants
    # Using \s* before < allows matching both "cat <" and "cat<"
    file_read_redirect = re.match(r"^\s*cat\s*<\s*\S+$", command)
    if file_read_match or file_read_redirect:
        # SECURITY FIX: Check for sensitive paths on normalized (unquoted) command
        # This prevents bypasses like cat '/etc/shadow' or cat "/etc/passwd"
        normalized_cmd = _normalize_command_for_checks(command)

        # Check for sensitive paths in the normalized command
        if _SENSITIVE_PATH_PATTERN.search(normalized_cmd):
            # SECURITY FIX: Attempt to read sensitive files is medium risk
            # Previously fell through to ambiguous/LLM which could return low risk
            return RegexClassificationResult(
                risk="medium",
                reasoning="Attempt to read sensitive system file detected",
                blocked=False,
                is_ambiguous=False,
            )
        elif _TRAVERSAL_PATTERN.search(normalized_cmd):
            # SECURITY FIX: Detect traversal patterns that could escape to sensitive paths
            # Check if the path with traversal might resolve to sensitive paths
            if _path_with_traversal_hits_sensitive(normalized_cmd):
                return RegexClassificationResult(
                    risk="ambiguous",
                    reasoning="Path traversal detected that could access sensitive system paths",
                    blocked=False,
                    is_ambiguous=True,
                )
            # Traversal but not to sensitive paths - allow
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: file reading (path traversal not targeting sensitive paths)",
                blocked=False,
                is_ambiguous=False,
            )
        else:
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: file reading (non-sensitive path)",
                blocked=False,
                is_ambiguous=False,
            )

    # Check system info commands (always safe)
    if re.match(
        r"^\s*(?:pwd|whoami|hostname|date|uptime|uname|env|printenv)\b", command
    ):
        return RegexClassificationResult(
            risk="none",
            reasoning="Safe pattern detected: system info",
            blocked=False,
            is_ambiguous=False,
        )

    # Check echo (EXCLUDES redirects and command substitution)
    if re.match(r"^\s*echo\b", command):
        # Check for dangerous characters
        if not _REDIRECT_PATTERN.search(command):
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: safe echo (no redirects or command substitution)",
                blocked=False,
                is_ambiguous=False,
            )

    # Check process listing (always safe)
    if re.match(r"^\s*(?:ps|pgrep)\b", command):
        return RegexClassificationResult(
            risk="none",
            reasoning="Safe pattern detected: process listing",
            blocked=False,
            is_ambiguous=False,
        )

    # Check command lookup (always safe)
    if re.match(r"^\s*(?:which|whereis|type|file)\s+\w+\s*$", command):
        return RegexClassificationResult(
            risk="none",
            reasoning="Safe pattern detected: command lookup",
            blocked=False,
            is_ambiguous=False,
        )

    # Check find (EXCLUDES -delete, -exec, -execdir)
    find_match = re.match(r"^\s*find\s+.*\s(?:-name|-type|-iname)\b", command)
    if find_match:
        # Check for destructive operations
        if not re.search(r"\s-(?:delete|exec|execdir)\b", command):
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: find with safe options (no -delete/-exec)",
                blocked=False,
                is_ambiguous=False,
            )

    # grep/rg - NOT blanket allowed if they have absolute paths
    # Check if grep/rg with absolute system paths -> fall through to LLM
    grep_match = re.match(r"^\s*(?:grep|rg|ag|ack)\s+(?:-[a-zA-Z0-9-]+\s+)*", command)
    if grep_match:
        # SECURITY FIX: Check normalized command for sensitive paths (handles quoted paths)
        normalized_cmd = _normalize_command_for_checks(command)

        # If it has absolute system paths, don't mark as safe - let LLM decide
        if _SENSITIVE_PATH_PATTERN.search(normalized_cmd):
            # Has sensitive paths - fall through to ambiguous
            pass  # Fall through to the ambiguous return below
        elif _TRAVERSAL_PATTERN.search(normalized_cmd):
            # SECURITY FIX: Detect traversal patterns that could escape to sensitive paths
            if _path_with_traversal_hits_sensitive(normalized_cmd):
                return RegexClassificationResult(
                    risk="ambiguous",
                    reasoning="Path traversal in grep could access sensitive system paths",
                    blocked=False,
                    is_ambiguous=True,
                )
            # Traversal but not to sensitive paths - allow
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: text search with path traversal (not targeting sensitive paths)",
                blocked=False,
                is_ambiguous=False,
            )
        else:
            # No sensitive paths - can be safe
            return RegexClassificationResult(
                risk="none",
                reasoning="Safe pattern detected: text search in project-local paths",
                blocked=False,
                is_ambiguous=False,
            )
    # No pattern matched - needs LLM assessment
    return RegexClassificationResult(
        risk="ambiguous",
        reasoning="No regex pattern matched; requires LLM assessment",
        blocked=False,
        is_ambiguous=True,
    )


def classify_command(command: str) -> RegexClassificationResult:
    """Classify a shell command using regex patterns.

    Implements two-pass classification:
    1. Whole-command scan for fork bombs and download-pipe patterns
       (these are dangerous even in quoted strings)
    2. Per-subcommand scan after splitting compound commands

    Fail-closed: Parse errors (unclosed quotes) result in blocking.

    Args:
        command: Shell command string to classify.

    Returns:
        RegexClassificationResult with classification details.

    Examples:
        >>> result = classify_command("rm -rf /")
        >>> result.blocked
        True
        >>> result = classify_command("ls -la")
        >>> result.risk
        'none'
        >>> result = classify_command("echo 'hello; rm foo'")
        >>> result.risk # Safe because ; is inside quotes
        'none'
    """
    # SECURITY FIX: Check command length limits to prevent regex DoS
    # Very long commands can cause performance issues with regex matching
    if len(command) > MAX_COMMAND_LENGTH:
        return RegexClassificationResult(
            risk="critical",
            reasoning=f"Command exceeds maximum length ({MAX_COMMAND_LENGTH} chars). Possible DoS attempt.",
            blocked=True,
            is_ambiguous=False,
        )

    line_count = command.count("\n") + 1
    if line_count > MAX_COMMAND_LINES:
        return RegexClassificationResult(
            risk="critical",
            reasoning=f"Command exceeds maximum line count ({MAX_COMMAND_LINES} lines). Possible DoS attempt.",
            blocked=True,
            is_ambiguous=False,
        )

    # First, do a whole-command scan for fork bombs and download-pipe patterns
    # These are dangerous even when quoted (e.g., `bash -c ":(){:|:&};:"`)
    # _WHOLE_COMMAND_DANGEROUS is defined at module level to avoid recompilation

    for pattern, description in _WHOLE_COMMAND_DANGEROUS:
        if pattern.search(command):
            return RegexClassificationResult(
                risk="critical",
                reasoning=f"High-risk pattern detected: {description}",
                blocked=True,
                is_ambiguous=False,
            )

    # Split compound commands for per-subcommand analysis
    sub_commands, parse_ok = _split_compound_command(command)

    # Fail closed on parse errors
    if not parse_ok:
        return RegexClassificationResult(
            risk="high",
            reasoning="Parse error: unclosed quotes detected",
            blocked=True,
            is_ambiguous=False,
        )

    # Single command - classify directly
    if len(sub_commands) == 1:
        return _classify_single_command(sub_commands[0])

    # Compound command - classify each subcommand and take max risk
    max_risk_level = -1
    max_risk_result: RegexClassificationResult | None = None

    for sub_cmd in sub_commands:
        result = _classify_single_command(sub_cmd)

        # Map risk to numeric level
        risk_numeric = {
            "none": 0,
            "low": 1,
            "medium": 2,
            "high": 3,
            "critical": 4,
            "ambiguous": 2,
        }.get(result.risk, 2)

        if risk_numeric > max_risk_level:
            max_risk_level = risk_numeric
            max_risk_result = result

        # Early exit if we find a critical risk
        if max_risk_level >= 4:
            break

    if max_risk_result is None:
        # Shouldn't happen, but fail safely
        return RegexClassificationResult(
            risk="ambiguous",
            reasoning="Compound command analysis failed",
            blocked=False,
            is_ambiguous=True,
        )

    # For compound commands, adjust reasoning to mention compound nature
    if max_risk_result.risk not in ("none", "ambiguous"):
        reasoning = (
            f"Compound command: sub-command triggered - {max_risk_result.reasoning}"
        )
    else:
        reasoning = max_risk_result.reasoning

    return RegexClassificationResult(
        risk=max_risk_result.risk,
        reasoning=reasoning,
        blocked=max_risk_result.blocked,
        is_ambiguous=max_risk_result.is_ambiguous,
    )
