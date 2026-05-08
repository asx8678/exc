"""Shared sensitive path definitions for Code Puppy.

This module provides a single source of truth for sensitive path definitions
used across the codebase to prevent security bypasses.

SECURITY RATIONALE:
    These definitions form a defense-in-depth layer that blocks access to:
    1. SSH keys (~/.ssh/*): Prevent exfiltration of private auth keys
    2. Cloud credentials: Prevent cloud account compromise
    3. System secrets: Prevent credential harvesting
    4. Private keys (.pem, .key): Prevent TLS/SSL key exfiltration
    5. Environment files: Prevent credential exposure

CRITICAL: Shell safety regex patterns must stay in sync with frozensets
below. Any path blocked by _is_sensitive_path() must also be blocked
by shell command filtering to prevent bypass vectors.
"""

import os
import re

# ============================================================================
# SENSITIVE DIRECTORY PREFIXES
# ============================================================================
# Directories where ALL contents are sensitive. Trailing sep prevents
# substring matches (e.g., /home/user/.sshfoo should NOT match /home/user/.ssh)

SENSITIVE_DIR_PREFIXES: frozenset[str] = frozenset(
    {
        os.path.join(os.path.expanduser("~"), ".ssh") + os.sep,
        os.path.join(os.path.expanduser("~"), ".aws") + os.sep,
        os.path.join(os.path.expanduser("~"), ".gnupg") + os.sep,
        os.path.join(os.path.expanduser("~"), ".gcp") + os.sep,
        os.path.join(os.path.expanduser("~"), ".config", "gcloud") + os.sep,
        os.path.join(os.path.expanduser("~"), ".azure") + os.sep,
        os.path.join(os.path.expanduser("~"), ".kube") + os.sep,
        os.path.join(os.path.expanduser("~"), ".docker") + os.sep,
    }
)

# ============================================================================
# SENSITIVE EXACT FILE MATCHES
# ============================================================================
# Specific files always considered sensitive at their canonical locations.

SENSITIVE_EXACT_FILES: frozenset[str] = frozenset(
    {
        # User credential files in home directory
        os.path.join(os.path.expanduser("~"), ".netrc"),
        os.path.join(os.path.expanduser("~"), ".pgpass"),
        os.path.join(os.path.expanduser("~"), ".my.cnf"),
        os.path.join(os.path.expanduser("~"), ".env"),
        os.path.join(os.path.expanduser("~"), ".bash_history"),
        os.path.join(os.path.expanduser("~"), ".npmrc"),
        os.path.join(os.path.expanduser("~"), ".pypirc"),
        os.path.join(os.path.expanduser("~"), ".gitconfig"),
        # System credential files
        "/etc/shadow",
        "/etc/sudoers",
        "/etc/passwd",
        "/etc/master.passwd",  # BSD/macOS
        # macOS /private/etc variants
        "/private/etc/shadow",
        "/private/etc/sudoers",
        "/private/etc/passwd",
        "/private/etc/master.passwd",
    }
)

# ============================================================================
# SENSITIVE FILENAMES
# ============================================================================
# Filenames that are sensitive anywhere they appear.

SENSITIVE_FILENAMES: frozenset[str] = frozenset({".env"})
ALLOWED_ENV_PATTERNS: frozenset[str] = frozenset(
    {".env.example", ".env.sample", ".env.template"}
)
SENSITIVE_FILENAME_PREFIXES: frozenset[str] = frozenset({".env."})
SENSITIVE_EXTENSIONS: frozenset[str] = frozenset(
    {".pem", ".key", ".p12", ".pfx", ".keystore"}
)

# ============================================================================
# REGEX PATTERNS FOR SHELL COMMAND FILTERING
# ============================================================================
# CRITICAL: Keep in sync with frozensets above! Each frozenset path must
# have a corresponding regex pattern to prevent shell command bypasses.

SENSITIVE_PATH_PATTERNS: list[str] = [
    # macOS system directories (was missing in original!)
    r"/private/etc",
    # Device files (was missing in original!)
    r"/dev",
    # Root user's home directory - distinct from /root (was missing!)
    r"~root",
    # Additional user's SSH via tilde expansion (cat ~other/.ssh/id_rsa)
    r"~[a-zA-Z_][a-zA-Z0-9_-]*/\.ssh",
    # Standard system directories
    r"/etc",
    r"/root",
    r"/proc",
    r"/var/log",
    # User SSH and cloud credentials
    r"~/.ssh",
    r"~/.aws",
    # Linux root home SSH
    r"/home/root/.ssh",
]


def get_sensitive_path_regex_pattern() -> re.Pattern[str]:
    """Return compiled regex for detecting sensitive paths in commands.

    Example:
        >>> pattern = get_sensitive_path_regex_pattern()
        >>> bool(pattern.search("cat /etc/shadow"))
        True
        >>> bool(pattern.search("cat /safe/file.txt"))
        False
    """
    combined = "(?:^|\\s|<<?<?)(?:" + "|".join(SENSITIVE_PATH_PATTERNS) + ")(?:/|$|\\s)"
    return re.compile(combined)


# Pre-compiled pattern for efficiency
SENSITIVE_PATH_REGEX_PATTERN: re.Pattern[str] = get_sensitive_path_regex_pattern()


def is_sensitive_path(file_path: str) -> bool:
    """Check if a path points to a sensitive file/directory.

        Used by file_operations and shell safety to block access to
    credentials, SSH keys, and other secrets — even in yolo_mode.

    Args:
            file_path: Path to check (may be relative, absolute, or contain ~).

        Returns:
            True if path is sensitive and should be blocked.
    """
    if not file_path:
        return False

    # Check if path starts with ~ followed by a username (e.g., ~root, ~other)
    # These need special handling since os.path.expanduser() handles them
    if file_path.startswith("~") and len(file_path) > 1 and file_path[1] != "/":
        # This is a ~username path, expand it
        try:
            expanded = os.path.expanduser(file_path)
            if expanded != file_path:  # Expansion succeeded
                # Check for other users' SSH directories
                if "/.ssh" in expanded:
                    return True
                # Check for root's home
                root_home = os.path.expanduser("~root")
                if root_home and expanded.startswith(root_home + os.sep):
                    return True
        except OSError, ValueError:
            pass

    try:
        expanded = os.path.abspath(os.path.expanduser(file_path))
        resolved = os.path.realpath(expanded)
    except OSError, ValueError:
        return False

    # Check directory prefixes (with trailing separator)
    for prefix in SENSITIVE_DIR_PREFIXES:
        if resolved.startswith(prefix):
            return True
        exact_dir = prefix.rstrip(os.sep)
        if resolved == exact_dir:
            return True

    # Check exact-match files
    if resolved in SENSITIVE_EXACT_FILES:
        return True

    # Check macOS /private/etc
    if resolved.startswith("/private/etc/"):
        return True

    # Check /dev directory
    if resolved.startswith("/dev/"):
        return True

    # Check sensitive filenames
    basename = os.path.basename(resolved)
    if basename in SENSITIVE_FILENAMES:
        return True

    # Check .env.* variants, but allow safe documentation files
    basename_lower = basename.lower()
    if basename_lower in ALLOWED_ENV_PATTERNS:
        return False
    if any(basename_lower.startswith(p) for p in SENSITIVE_FILENAME_PREFIXES):
        return True

    # Check for private key files by extension
    _, ext = os.path.splitext(resolved)
    if ext.lower() in SENSITIVE_EXTENSIONS:
        return True

    return False
