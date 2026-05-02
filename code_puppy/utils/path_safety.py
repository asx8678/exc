"""Shared path safety utilities for filesystem operations.

Provides defense-in-depth against path traversal attacks and unsafe filename
manipulation when handling user or LLM-generated input that flows to filesystem
call sites.

Security considerations:
- All path components should be sanitized before use in filesystem operations
- Directory containment should be verified before writing files
- Path resolution must happen before relative path checks

Example usage:
    >>> from code_puppy.utils.path_safety import safe_path_component, verify_contained
    >>> safe_name = safe_path_component(user_input)
    >>> final_path = verify_contained(base_dir / safe_name, base_dir)
"""

import re
from pathlib import Path
from typing import Final

# Allowlist pattern: alphanumeric, underscore, hyphen only
# Explicitly rejects: / \ : null bytes .. and other traversal-ish patterns
_SAFE_COMPONENT_PATTERN: Final[re.Pattern[str]] = re.compile(r"^[a-zA-Z0-9_-]+$")

# Forbidden characters that indicate path traversal attempts
_FORBIDDEN_CHARS: Final[frozenset[str]] = frozenset("/\\:\x00.")

# Default maximum length for path components
_DEFAULT_MAX_LEN: Final[int] = 64


class PathSafetyError(ValueError):
    """Raised when a path safety check fails.

    This is a security-sensitive error that indicates potential path traversal
    or unsafe filename injection attempts.
    """

    pass


class PathTraversalError(PathSafetyError):
    """Raised when a path escapes its intended root directory.

    Indicates a potential directory traversal attack.
    """

    pass


class UnsafeComponentError(PathSafetyError):
    """Raised when a path component contains unsafe characters.

    Indicates a potential filename injection or path traversal attempt.
    """

    pass


def safe_path_component(name: str, max_len: int = _DEFAULT_MAX_LEN) -> str:
    """Sanitize a single path component (filename or directory name).

    Validates that the name:
    1. Contains only allowlisted characters [a-zA-Z0-9_-]
    2. Does not contain path separators (/ or backslash), null bytes, or dots
    3. Does not exceed max_len characters
    4. Is not empty

    Args:
        name: The path component to sanitize (e.g., filename, directory name)
        max_len: Maximum allowed length (default: 64). Must be >= 1.

    Returns:
        The sanitized name unchanged if it passes all checks.

    Raises:
        UnsafeComponentError: If the name contains forbidden characters,
            is empty, exceeds max_len, or fails the allowlist regex.

    Examples:
        >>> safe_path_component("my_file.txt")  # Raises UnsafeComponentError (has dot)
        >>> safe_path_component("my_file")  # Returns "my_file"
        >>> safe_path_component("../../etc/passwd")  # Raises UnsafeComponentError
        >>> safe_path_component("a" * 100, max_len=64)  # Raises UnsafeComponentError
    """
    if not isinstance(name, str):
        raise UnsafeComponentError(f"name must be a string, got {type(name).__name__}")

    if not name:
        raise UnsafeComponentError("name must not be empty")

    if max_len < 1:
        raise UnsafeComponentError(f"max_len must be >= 1, got {max_len}")

    if len(name) > max_len:
        raise UnsafeComponentError(
            f"name exceeds maximum length of {max_len} characters: "
            f"{len(name)} characters"
        )

    # Fast path: check for forbidden characters
    # This catches path separators, null bytes, and dots (which could be used for traversal)
    if any(c in _FORBIDDEN_CHARS for c in name):
        # Find which forbidden characters were found for better error message
        found = [repr(c) for c in _FORBIDDEN_CHARS if c in name]
        raise UnsafeComponentError(
            f"name contains forbidden characters ({', '.join(found)}); "
            f"only alphanumeric, underscore, and hyphen are allowed: {name!r}"
        )

    # Validate against allowlist regex
    if not _SAFE_COMPONENT_PATTERN.match(name):
        raise UnsafeComponentError(
            f"name must match pattern '^[a-zA-Z0-9_-]+$'; got {name!r}"
        )

    return name


def verify_contained(path: Path, root: Path) -> Path:
    """Verify that a resolved path is contained within a root directory.

    This is a defense-in-depth check against directory traversal attacks.
    Both paths are resolved (made absolute, symlinks followed) before checking
    containment.

    Args:
        path: The path to verify (file or directory). Can be relative or absolute.
        root: The root directory that must contain path. Can be relative or absolute.

    Returns:
        The resolved path if it is contained within the resolved root.

    Raises:
        PathTraversalError: If the resolved path is not contained under
            the resolved root directory (possible traversal attack).
        PathSafetyError: If path resolution fails (e.g., broken symlinks,
            permission errors).

    Examples:
        >>> verify_contained(Path("/safe/dir/file.txt"), Path("/safe"))
        PosixPath('/safe/dir/file.txt')

        >>> verify_contained(Path("/safe/../etc/passwd"), Path("/safe"))
        PathTraversalError: resolved path escapes root

        >>> verify_contained(Path("subdir/file.txt"), Path("/safe"))
        # Resolves to absolute path under /safe
    """
    if not isinstance(path, Path):
        raise PathSafetyError(f"path must be a Path, got {type(path).__name__}")

    if not isinstance(root, Path):
        raise PathSafetyError(f"root must be a Path, got {type(root).__name__}")

    try:
        # Resolve both paths to absolute paths with symlink resolution
        # This collapses .. components and follows symlinks
        resolved_path = path.resolve()
        resolved_root = root.resolve()
    except OSError as exc:
        raise PathSafetyError(f"Failed to resolve paths: {exc}") from exc

    # Ensure root is actually a directory path
    # Using str.endswith('/') check after resolve() because Path.parent
    # behavior can be tricky with root directories
    try:
        # Check if resolved_path is the same as or under resolved_root
        # relative_to() raises ValueError if not a subpath
        resolved_path.relative_to(resolved_root)
    except ValueError as exc:
        raise PathTraversalError(
            f"Path {resolved_path!r} is not contained within root {resolved_root!r}; "
            f"possible path traversal attack"
        ) from exc

    return resolved_path


def safe_join(root: Path, *components: str) -> Path:
    """Safely join path components with root, verifying containment.

    This combines safe_path_component sanitization with verify_contained
    in one convenient helper for the common case of building a path
    under a root directory from user/LLM input.

    Args:
        root: The root directory that must contain the final path.
        *components: Path components to sanitize and join (e.g., filename,
            subdirectory). Each component is passed through safe_path_component().

    Returns:
        The resolved, verified path that is confirmed to be under root.

    Raises:
        UnsafeComponentError: If any component fails sanitization.
        PathTraversalError: If the final path escapes root (shouldn't happen
            with properly sanitized components, but checked for defense-in-depth).

    Examples:
        >>> safe_join(Path("/safe"), "subdir", "my_file")
        PosixPath('/safe/subdir/my_file')

        >>> safe_join(Path("/safe"), "../etc")  # Raises UnsafeComponentError
    """
    # Sanitize all components
    safe_components = [safe_path_component(c) for c in components]

    # Build the path
    result = root.joinpath(*safe_components)

    # Verify containment (defense-in-depth)
    return verify_contained(result, root)
