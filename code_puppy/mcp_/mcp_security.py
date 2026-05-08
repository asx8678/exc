"""
MCP Security Module - Input validation and security controls for MCP servers.

This module provides security controls to prevent arbitrary command execution
through MCP server configurations. It implements:
- Command whitelist validation
- Input sanitization
- Path traversal protection
- Shell injection detection
"""

import os
import re
from pathlib import Path
from typing import Any

# Whitelist of allowed commands for MCP stdio servers
# These are well-known, safe package managers and interpreters
ALLOWED_COMMANDS = frozenset(
    [
        # Package managers
        "npx",
        "npm",
        "node",
        "uvx",
        "uv",
        "pip",
        "pip3",
        "python",
        "python3",
        # Interpreters
        "node",
        "python",
        "python3",
        "ruby",
        "php",
        "perl",
        "julia",
        "R",
        "java",
        # Tools
        "git",
        "docker",
        "kubectl",
        "terraform",
        "op",  # 1Password CLI
        "code",  # VS Code
        "jupyter",
        "swift",
        "go",
        "cargo",
        "rustc",
        "dotnet",
    ]
)

# Dangerous shell metacharacters that could enable command injection
DANGEROUS_SHELL_CHARS = frozenset(
    [
        ";",  # Command separator
        "&",  # Background/command separator
        "|",  # Pipe
        "$",  # Variable expansion (except ${...} which we handle separately)
        "`",  # Command substitution
        "(",
        ")",  # Subshell
        "{",
        "}",  # Command grouping (when not used for placeholders)
        "<",
        ">",  # Redirection
        "!",  # History expansion
        "*",  # Glob (can be dangerous in some contexts)
        "?",  # Glob
        "[",
        "]",  # Glob
        "\\",  # Escape character
        "'",
        '"',  # Quote manipulation
        "\n",  # Newline injection
        "\r",  # Carriage return
    ]
)

# Dangerous command sequences (case-insensitive)
DANGEROUS_PATTERNS = [
    r"rm\s+-rf\s+/",
    r"rm\s+-rf\s+~",
    r"rm\s+-rf\s+\$HOME",
    r">\s*/etc/",
    r">\s*/var/",
    r"curl.*\|.*sh",
    r"curl.*\|.*bash",
    r"wget.*\|.*sh",
    r"wget.*\|.*bash",
    r"eval\s*\(",
    r"exec\s*\(",
    r"system\s*\(",
    r"subprocess\.call",
    r"os\.system",
    r"__import__",
    r"import\s+os",
    r"import\s+subprocess",
]


class MCPSecurityError(Exception):
    """Security validation error for MCP configuration."""

    pass


class CommandNotAllowedError(MCPSecurityError):
    """Raised when a command is not in the whitelist."""

    pass


class CommandInjectionError(MCPSecurityError):
    """Raised when potential command injection is detected."""

    pass


class PathTraversalError(MCPSecurityError):
    """Raised when path traversal is detected."""

    pass


class InvalidArgumentError(MCPSecurityError):
    """Raised when an argument fails security validation."""

    pass


def validate_command_whitelist(command: str) -> str:
    """
    Validate that a command is in the allowed whitelist.

    Args:
        command: The command to validate

    Returns:
        The cleaned command string

    Raises:
        CommandNotAllowedError: If command is not in the whitelist
    """
    if not command or not isinstance(command, str):
        raise CommandNotAllowedError("Command must be a non-empty string")

    # Strip whitespace
    command = command.strip()

    # Extract base command (handles cases like "/usr/bin/npx" -> "npx")
    if "/" in command or "\\" in command:
        # It's a path - get the basename
        base_cmd = os.path.basename(command)
        # Also validate the full path doesn't contain dangerous sequences
        if ".." in command or "~" in command:
            # Allow absolute paths but not relative paths with .. or ~
            if not command.startswith(
                ("/usr/", "/bin/", "/opt/", "/usr/local/", "C:\\\\", "C:/")
            ):
                raise CommandNotAllowedError(
                    f"Command path contains unsafe elements: {command}. "
                    f"Only absolute paths to system directories are allowed."
                )
    else:
        base_cmd = command

    # Check against whitelist
    if base_cmd not in ALLOWED_COMMANDS:
        raise CommandNotAllowedError(
            f"Command '{base_cmd}' is not in the allowed whitelist. "
            f"Allowed commands: {', '.join(sorted(ALLOWED_COMMANDS))}"
        )

    return command


def detect_shell_injection(value: str) -> bool:
    """
    Detect potential shell injection in a string value.

    Args:
        value: The string to check

    Returns:
        True if potential injection detected, False otherwise
    """
    if not isinstance(value, str):
        return False

    # Check for dangerous shell metacharacters (except in safe contexts)
    for char in DANGEROUS_SHELL_CHARS:
        if char in value:
            # Special handling: $ is OK for environment variables like $HOME
            # but not for command substitution like $(...)
            if char == "$":
                if "$(" in value or "${" in value:
                    return True
                continue  # Allow simple $VAR syntax
            return True

    # Check for dangerous patterns
    value_lower = value.lower()
    for pattern in DANGEROUS_PATTERNS:
        if re.search(pattern, value_lower, re.IGNORECASE):
            return True

    return False


def sanitize_argument(arg: str) -> str:
    """
    Sanitize a single command argument to prevent injection.

    Args:
        arg: The argument to sanitize

    Returns:
        Sanitized argument

    Raises:
        CommandInjectionError: If dangerous content is detected
    """
    if not isinstance(arg, str):
        arg = str(arg)

    # Check for shell injection
    if detect_shell_injection(arg):
        raise CommandInjectionError(
            f"Potential command injection detected in argument: {arg!r}. "
            f"Arguments cannot contain shell metacharacters."
        )

    return arg


def validate_arguments(args: list[str] | str) -> list[str]:
    """
    Validate and sanitize all command arguments.

    Args:
        args: List of arguments to validate, or a string to be split

    Returns:
        List of sanitized arguments

    Raises:
        InvalidArgumentError: If any argument fails validation
    """
    if args is None:
        return []

    # Handle string args by splitting them
    if isinstance(args, str):
        import shlex

        try:
            args = shlex.split(args)
        except ValueError:
            args = args.split()

    if not isinstance(args, (list, tuple)):
        raise InvalidArgumentError(
            f"Arguments must be a list or string, got {type(args).__name__}"
        )

    sanitized = []
    for i, arg in enumerate(args):
        try:
            sanitized.append(sanitize_argument(str(arg)))
        except CommandInjectionError as e:
            raise InvalidArgumentError(f"Argument {i} is unsafe: {e}")

    return sanitized


def validate_working_directory(cwd: str) -> str:
    """
    Validate working directory path to prevent path traversal attacks.

    Args:
        cwd: The working directory path

    Returns:
        Normalized, validated path

    Raises:
        PathTraversalError: If path traversal is detected
    """
    if not cwd:
        return cwd

    if not isinstance(cwd, str):
        raise PathTraversalError("Working directory must be a string")

    # Expand user home directory safely
    if cwd.startswith("~/"):
        cwd = os.path.expanduser(cwd)

    # Convert to absolute path and normalize
    try:
        cwd_path = Path(cwd).resolve()
    except Exception as e:
        raise PathTraversalError(f"Invalid path: {e}")

    # Check for path traversal sequences in original path
    cwd_str = str(cwd)
    if ".." in cwd_str or cwd_str.startswith("/") is False:
        # Relative paths are only allowed if they don't contain ..
        if ".." in cwd_str:
            raise PathTraversalError(
                f"Path traversal detected in working directory: {cwd}"
            )

    # Final safety check: resolved path should not contain .. components
    resolved_str = str(cwd_path)
    if "/../" in resolved_str or resolved_str.endswith("/.."):
        raise PathTraversalError(
            f"Path traversal detected in resolved working directory: {resolved_str}"
        )

    return str(cwd_path)


def validate_environment_variables(env: dict[str, str]) -> dict[str, str]:
    """
    Validate environment variables to prevent injection.

    Args:
        env: Dictionary of environment variables

    Returns:
        Sanitized environment dictionary

    Raises:
        InvalidArgumentError: If any variable fails validation
    """
    if env is None:
        return {}

    if not isinstance(env, dict):
        raise InvalidArgumentError("Environment variables must be a dictionary")

    sanitized = {}
    for key, value in env.items():
        # Validate key is a valid environment variable name
        if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", key):
            raise InvalidArgumentError(f"Invalid environment variable name: {key!r}")

        # Validate value doesn't contain dangerous content
        try:
            if isinstance(value, str):
                sanitized[key] = sanitize_argument(value)
            else:
                sanitized[key] = str(value)
        except CommandInjectionError as e:
            raise InvalidArgumentError(
                f"Environment variable '{key}' has unsafe value: {e}"
            )

    return sanitized


def validate_stdio_config(config: dict[str, Any]) -> dict[str, Any]:
    """
    Validate a complete stdio server configuration for security issues.

    Args:
        config: The server configuration dictionary containing
                'command', 'args', 'cwd', 'env'

    Returns:
        Sanitized configuration dictionary

    Raises:
        MCPSecurityError: If the configuration fails security checks
    """
    if not isinstance(config, dict):
        raise MCPSecurityError("Configuration must be a dictionary")

    result = dict(config)  # Copy to avoid mutating original

    # Validate command
    if "command" in config:
        result["command"] = validate_command_whitelist(config["command"])

    # Validate arguments
    if "args" in config:
        result["args"] = validate_arguments(config["args"])

    # Validate working directory
    if "cwd" in config:
        result["cwd"] = validate_working_directory(config["cwd"])

    # Validate environment variables
    if "env" in config:
        result["env"] = validate_environment_variables(config["env"])

    return result


def safe_expand_placeholders(template: str, values: dict[str, Any]) -> str:
    """
    Safely expand placeholders like ${key} with validation.

    This is a secure replacement for simple string replacement that
    validates the substituted values don't contain dangerous content.

    Args:
        template: The template string containing ${key} placeholders
        values: Dictionary of values to substitute

    Returns:
        String with placeholders replaced

    Raises:
        CommandInjectionError: If a substituted value contains dangerous content
    """
    if not isinstance(template, str):
        return str(template)

    result = template
    for key, value in values.items():
        placeholder = f"${{{key}}}"
        if placeholder in result:
            str_value = str(value)

            # Validate the substituted value
            if detect_shell_injection(str_value):
                raise CommandInjectionError(
                    f"Unsafe value for '{key}': {str_value!r}. "
                    f"Cannot substitute values containing shell metacharacters."
                )

            result = result.replace(placeholder, str_value)

    return result


def safe_expand_env_vars(value: Any) -> Any:
    """
    Safely expand environment variables with security checks.

    This is a secure replacement for os.path.expandvars that:
    1. Only expands well-known safe environment variables
    2. Validates expanded values don't contain dangerous content
    3. Sanitizes the final result

    Args:
        value: Value to expand (string, dict, or list)

    Returns:
        Value with safe environment variables expanded
    """
    # List of safe environment variables that can be expanded
    SAFE_ENV_VARS = frozenset(
        [
            "HOME",
            "USER",
            "USERPROFILE",
            "APPDATA",
            "LOCALAPPDATA",
            "TMPDIR",
            "TMP",
            "TEMP",
            "PATH",
            "SHELL",
            "TERM",
            "LANG",
            "LC_ALL",
        ]
    )

    if isinstance(value, str):
        result = value
        # Only expand safe environment variables
        for var_name in SAFE_ENV_VARS:
            var_value = os.environ.get(var_name, "")
            if var_value:
                # Validate the environment variable value is safe
                if detect_shell_injection(var_value):
                    # Don't expand unsafe env vars
                    continue
                result = result.replace(f"${var_name}", var_value)
                result = result.replace(f"${{{var_name}}}", var_value)
        return result

    elif isinstance(value, dict):
        return {k: safe_expand_env_vars(v) for k, v in value.items()}

    elif isinstance(value, list):
        return [safe_expand_env_vars(item) for item in value]

    return value


def get_allowed_commands() -> frozenset[str]:
    """Get the set of allowed commands for documentation purposes."""
    return ALLOWED_COMMANDS


def is_command_allowed(command: str) -> bool:
    """Check if a command is in the allowed whitelist without raising."""
    try:
        validate_command_whitelist(command)
        return True
    except CommandNotAllowedError:
        return False
