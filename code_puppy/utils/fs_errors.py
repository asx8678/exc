"""Type-safe filesystem error checking utilities.

Ported from oh-my-pi's fs-error.ts pattern, adapted to Python's errno system.

Provides convenience functions to check filesystem error types without
scattered ``isinstance(e, OSError) and e.errno == errno.ENOENT`` patterns.

Usage:
    from code_puppy.utils.fs_errors import is_enoent, is_eacces

    try:
        content = path.read_text()
    except OSError as exc:
        if is_enoent(exc):
            return None  # File doesn't exist
        if is_eacces(exc):
            raise PermissionError(f"Cannot read {path}") from exc
        raise
"""

import errno

__all__ = [
    "is_fs_error",
    "is_enoent",
    "is_eacces",
    "is_eisdir",
    "is_enotdir",
    "is_eexist",
    "is_enotempty",
    "is_eperm",
    "is_enospc",
    "is_erofs",
    "has_fs_code",
    "get_fs_code",
]


def is_fs_error(exc: BaseException) -> bool:
    """Check if an exception is a filesystem-related OS error.

    Returns True for OSError and all its subclasses (FileNotFoundError,
    PermissionError, IsADirectoryError, etc.).

    Args:
        exc: The exception to check.

    Returns:
        True if the exception is an OSError.
    """
    return isinstance(exc, OSError)


def is_enoent(exc: BaseException) -> bool:
    """Check if an exception is ENOENT (No such file or directory).

    Matches both ``OSError(errno=ENOENT)`` and ``FileNotFoundError``.

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "file not found".
    """
    return isinstance(exc, FileNotFoundError) or (
        isinstance(exc, OSError) and exc.errno == errno.ENOENT
    )


def is_eacces(exc: BaseException) -> bool:
    """Check if an exception is EACCES (Permission denied).

    Matches both ``OSError(errno=EACCES)`` and ``PermissionError``.

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "permission denied".
    """
    return isinstance(exc, PermissionError) or (
        isinstance(exc, OSError) and exc.errno == errno.EACCES
    )


def is_eisdir(exc: BaseException) -> bool:
    """Check if an exception is EISDIR (Is a directory).

    Matches both ``OSError(errno=EISDIR)`` and ``IsADirectoryError``.

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "is a directory".
    """
    return isinstance(exc, IsADirectoryError) or (
        isinstance(exc, OSError) and exc.errno == errno.EISDIR
    )


def is_enotdir(exc: BaseException) -> bool:
    """Check if an exception is ENOTDIR (Not a directory).

    Matches both ``OSError(errno=ENOTDIR)`` and ``NotADirectoryError``.

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "not a directory".
    """
    return isinstance(exc, NotADirectoryError) or (
        isinstance(exc, OSError) and exc.errno == errno.ENOTDIR
    )


def is_eexist(exc: BaseException) -> bool:
    """Check if an exception is EEXIST (File exists).

    Matches both ``OSError(errno=EEXIST)`` and ``FileExistsError``.

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "file already exists".
    """
    return isinstance(exc, FileExistsError) or (
        isinstance(exc, OSError) and exc.errno == errno.EEXIST
    )


def is_enotempty(exc: BaseException) -> bool:
    """Check if an exception is ENOTEMPTY (Directory not empty).

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "directory not empty".
    """
    return isinstance(exc, OSError) and exc.errno == errno.ENOTEMPTY


def is_eperm(exc: BaseException) -> bool:
    """Check if an exception is EPERM (Operation not permitted).

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "operation not permitted".
    """
    return isinstance(exc, OSError) and exc.errno == errno.EPERM


def is_enospc(exc: BaseException) -> bool:
    """Check if an exception is ENOSPC (No space left on device).

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "no space left on device".
    """
    return isinstance(exc, OSError) and exc.errno == errno.ENOSPC


def is_erofs(exc: BaseException) -> bool:
    """Check if an exception is EROFS (Read-only file system).

    Args:
        exc: The exception to check.

    Returns:
        True if the error is "read-only file system".
    """
    return isinstance(exc, OSError) and exc.errno == errno.EROFS


def has_fs_code(exc: BaseException, code: int) -> bool:
    """Check if an exception has a specific filesystem error code.

    Generic version for error codes not covered by the specific helpers.

    Args:
        exc: The exception to check.
        code: The errno code to match (e.g., ``errno.EMLINK``).

    Returns:
        True if the exception is an OSError with the given code.
    """
    return isinstance(exc, OSError) and exc.errno == code


def get_fs_code(exc: BaseException) -> int | None:
    """Extract the errno code from a filesystem exception.

    Args:
        exc: The exception to inspect.

    Returns:
        The errno code if present, or None.
    """
    if isinstance(exc, OSError):
        return exc.errno
    return None
