"""Clean command plugin — /clean for clearing sessions, history, logs, and caches.

Registers via the ``custom_command`` hook so it lives entirely outside
``code_puppy/command_line/``.  Run ``/clean help`` for usage.
"""

import shutil
from pathlib import Path
from typing import Any

from code_puppy import config
from code_puppy.callbacks import register_callback
from code_puppy.config_paths import resolve_path
from code_puppy.dbos_utils import reinitialize_dbos
from code_puppy.messaging import emit_error, emit_info, emit_success, emit_warning

# ---------------------------------------------------------------------------
# Storage location definitions
# ---------------------------------------------------------------------------

# Each category maps to a list of (label, path, kind) tuples.
# kind is "dir" (clean contents) or "file" (unlink).


def _session_targets() -> list[tuple[str, Path, str]]:
    return [
        ("Autosave sessions", Path(config.AUTOSAVE_DIR), "dir"),
        ("Sub-agent sessions", Path(config.DATA_DIR) / "subagent_sessions", "dir"),
        (
            "Terminal sessions",
            Path(config.STATE_DIR) / "terminal_sessions.json",
            "file",
        ),
        ("Session HMAC key", Path(config.DATA_DIR) / ".session_hmac_key", "file"),
        ("Last agent", Path(config.STATE_DIR) / "last_agent.json", "file"),
    ]


def _history_targets() -> list[tuple[str, Path, str]]:
    return [
        ("Command history", Path(config.COMMAND_HISTORY_FILE), "file"),
    ]


def _log_targets() -> list[tuple[str, Path, str]]:
    return [
        ("Error logs", Path(config.STATE_DIR) / "logs", "dir"),
    ]


def _cache_targets() -> list[tuple[str, Path, str]]:
    return [
        ("Browser profiles", Path(config.CACHE_DIR) / "browser_profiles", "dir"),
        ("Browser workflows", Path(config.DATA_DIR) / "browser_workflows", "dir"),
        (
            "Skills cache",
            resolve_path("cache") / "skills_catalog.json",
            "file",
        ),
        ("API server PID", Path(config.STATE_DIR) / "api_server.pid", "file"),
    ]


def _db_targets() -> list[tuple[str, Path, str]]:
    """DBOS database and its WAL/SHM journal files."""
    db_path = Path(config.DATA_DIR) / "dbos_store.sqlite"
    targets: list[tuple[str, Path, str]] = [
        ("DBOS database", db_path, "file"),
    ]
    # Include WAL/SHM journal files when they exist (status + cleanup)
    for suffix in ("-wal", "-shm"):
        journal = db_path.parent / (db_path.name + suffix)
        if journal.is_file():
            targets.append((f"DBOS journal ({suffix})", journal, "file"))
    return targets


_CATEGORIES: dict[str, Any] = {
    "sessions": ("Sessions", _session_targets),
    "history": ("History", _history_targets),
    "logs": ("Logs", _log_targets),
    "cache": ("Cache", _cache_targets),
    "db": ("Database", _db_targets),
}

# Categories safe to include in "/clean all".
# The "db" category is excluded because deleting the DBOS SQLite database
# while DBOS holds an active connection causes
# ``sqlite3.OperationalError: attempt to write a readonly database``.
# Users must run "/clean db" explicitly (which destroys DBOS first).
_SAFE_CATEGORY_KEYS: list[str] = [k for k in _CATEGORIES if k != "db"]

# ---------------------------------------------------------------------------
# Size / cleanup helpers
# ---------------------------------------------------------------------------


def _human_size(nbytes: int) -> str:
    """Format *nbytes* as a human-friendly string."""
    if nbytes < 1024:
        return f"{nbytes} B"
    for unit in ("KB", "MB", "GB"):
        nbytes /= 1024.0
        if nbytes < 1024.0 or unit == "GB":
            return f"{nbytes:.1f} {unit}"
    return f"{nbytes:.1f} GB"  # pragma: no cover


def _dir_stats(path: Path) -> tuple[int, int]:
    """Return ``(file_count, total_bytes)`` for a directory tree."""
    if not path.is_dir():
        return 0, 0
    count = 0
    total = 0
    try:
        for item in path.rglob("*"):
            if item.is_file():
                try:
                    total += item.stat().st_size
                    count += 1
                except OSError:
                    pass
    except OSError:
        pass
    return count, total


def _file_stats(path: Path) -> tuple[int, int]:
    """Return ``(1, size)`` if file exists, else ``(0, 0)``."""
    if not path.is_file():
        return 0, 0
    try:
        return 1, path.stat().st_size
    except OSError:
        return 0, 0


def _target_stats(targets: list[tuple[str, Path, str]]) -> tuple[int, int]:
    """Aggregate file count and byte total across all targets."""
    count = 0
    total = 0
    for _label, path, kind in targets:
        if kind == "dir":
            c, t = _dir_stats(path)
        else:
            c, t = _file_stats(path)
        count += c
        total += t
    return count, total


def _clean_dir(path: Path, dry_run: bool) -> tuple[int, int]:
    """Remove **contents** of *path* (not the dir itself).

    Returns ``(files_removed, bytes_freed)``.
    """
    if not path.is_dir():
        return 0, 0
    count, total = _dir_stats(path)
    if dry_run or count == 0:
        return count, total
    try:
        shutil.rmtree(path)
    except OSError as exc:
        emit_warning(f"  ⚠️  Could not fully clean {path}: {exc}")
    finally:
        path.mkdir(parents=True, exist_ok=True)
    return count, total


def _clean_file(path: Path, dry_run: bool) -> tuple[int, int]:
    """Remove a single file.  Returns ``(1, size)`` or ``(0, 0)``."""
    if not path.is_file():
        return 0, 0
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    if dry_run:
        return 1, size
    try:
        path.unlink()
    except OSError as exc:
        emit_warning(f"  ⚠️  Could not remove {path}: {exc}")
        return 0, 0
    return 1, size


def _clean_targets(
    targets: list[tuple[str, Path, str]], dry_run: bool
) -> tuple[int, int]:
    """Clean all targets in a list, emitting per-target output.

    Returns ``(total_files, total_bytes)`` across all targets.
    """
    total_files = 0
    total_bytes = 0
    for label, path, kind in targets:
        if kind == "dir":
            c, b = _clean_dir(path, dry_run)
        else:
            c, b = _clean_file(path, dry_run)
        if c:
            prefix = "Would remove" if dry_run else "Removed"
            emit_info(
                f"  🗑️  {prefix} {label}: {c} file{'s' if c != 1 else ''}, {_human_size(b)}"
            )
        total_files += c
        total_bytes += b
    return total_files, total_bytes


# ---------------------------------------------------------------------------
# DBOS-safe database cleanup
# ---------------------------------------------------------------------------


def _destroy_dbos() -> bool:
    """Attempt to gracefully shut down DBOS.  Returns True on success."""
    try:
        from dbos import DBOS

        DBOS.destroy()
        return True
    except Exception:
        return False


def _clean_db(dry_run: bool) -> tuple[int, int]:
    """Clean the DBOS database with safety handling.

    Unlike other categories, the ``db`` category must destroy the active DBOS
    connection **before** deleting the underlying SQLite file.  Deleting while
    DBOS holds an open connection causes
    ``sqlite3.OperationalError: attempt to write a readonly database``.

    Returns ``(total_files, total_bytes)``.
    """
    if not dry_run:
        if _destroy_dbos():
            emit_info("  🔌 DBOS connection closed")
        else:
            emit_warning(
                "  ⚠️  Could not close DBOS connection — database may still be locked"
            )

    _, target_fn = _CATEGORIES["db"]
    targets = target_fn()
    total_files, total_bytes = _clean_targets(targets, dry_run)

    if not dry_run and total_files > 0:
        if reinitialize_dbos():
            emit_info("  🔄 DBOS reinitialized successfully")
        else:
            emit_warning(
                "  ⚠️  Could not reinitialize DBOS automatically - you may need to restart"
            )

    return total_files, total_bytes


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------


def _show_help() -> None:
    """Print help text for /clean."""
    emit_info("🧹 /clean — Clean Code Puppy session data, logs, and caches\n")
    emit_info("Usage:")
    emit_info("  /clean help              Show this help message")
    emit_info("  /clean status            Show disk usage per category")
    emit_info(
        "  /clean all               Clean everything except db (sessions, history, logs, cache)"
    )
    emit_info(
        "  /clean sessions          Clean autosave + sub-agent + terminal sessions"
    )
    emit_info("  /clean history           Clean command history")
    emit_info("  /clean logs              Clean error logs")
    emit_info(
        "  /clean cache             Clean browser profiles, workflows, skills cache"
    )
    emit_info(
        "  /clean db                Clean DBOS state database (auto-reinitializes)"
    )
    emit_info("")
    emit_info("Options:")
    emit_info(
        "  --dry-run                Preview what would be cleaned without deleting"
    )
    emit_info("")
    emit_info("Examples:")
    emit_info("  /clean sessions --dry-run")
    emit_info("  /clean --dry-run all")
    emit_info("")
    emit_info("⚠️  Config files (puppy.cfg, mcp_servers.json, models, OAuth tokens)")
    emit_info("   are never touched.")
    emit_info(
        "💡 /clean all excludes db — use /clean db explicitly (auto-reinitializes)."
    )


def _show_status() -> None:
    """Print disk usage per category."""
    emit_info("📊 Code Puppy Storage Status\n")
    grand_files = 0
    grand_bytes = 0
    for key, (display_name, target_fn) in _CATEGORIES.items():
        targets = target_fn()
        count, total = _target_stats(targets)
        grand_files += count
        grand_bytes += total
        count_str = f"{count} file{'s' if count != 1 else ''}"
        emit_info(f"  {display_name:<20s} {count_str:>12s}  {_human_size(total):>10s}")
    emit_info("  " + "─" * 44)
    emit_info(
        f"  {'Total':<20s} {grand_files:>6d} file{'s' if grand_files != 1 else '':5s} {_human_size(grand_bytes):>10s}"
    )


def _run_clean(categories: list[str], dry_run: bool) -> None:
    """Execute a clean across the given category keys."""
    if dry_run:
        emit_info("🔍 Dry run — nothing will be deleted\n")
    else:
        emit_info("🧹 Cleaning Code Puppy data...\n")

    grand_files = 0
    grand_bytes = 0
    for key in categories:
        if key == "db":
            # db category requires special DBOS-safe handling
            files, nbytes = _clean_db(dry_run)
        else:
            display_name, target_fn = _CATEGORIES[key]
            targets = target_fn()
            files, nbytes = _clean_targets(targets, dry_run)
        grand_files += files
        grand_bytes += nbytes

    if grand_files == 0:
        emit_info("\n✨ Nothing to clean — already squeaky clean!")
    elif dry_run:
        emit_info(
            f"\n📋 Would clean {grand_files} file{'s' if grand_files != 1 else ''}"
            f" ({_human_size(grand_bytes)})"
        )
    else:
        emit_success(
            f"\n✅ Cleaned {grand_files} file{'s' if grand_files != 1 else ''}"
            f" ({_human_size(grand_bytes)})"
        )


# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------

_VALID_SUBCMDS = {"help", "status", "all", "sessions", "history", "logs", "cache", "db"}


def _handle_clean_command(command: str, name: str) -> bool | None:
    """Handle ``/clean`` and its subcommands.

    Returns ``True`` when the command was handled, ``None`` otherwise.
    """
    if name != "clean":
        return None

    # Parse arguments after "/clean"
    parts = command.split()[1:]  # drop "/clean" itself

    # Detect --dry-run anywhere in args
    dry_run = "--dry-run" in parts
    args = [a for a in parts if a != "--dry-run"]

    subcmd = args[0] if args else "help"

    try:
        if subcmd == "help":
            _show_help()
        elif subcmd == "status":
            _show_status()
        elif subcmd == "all":
            _run_clean(_SAFE_CATEGORY_KEYS, dry_run)
        elif subcmd in _CATEGORIES:
            _run_clean([subcmd], dry_run)
        else:
            emit_warning(f"Unknown subcommand: {subcmd}")
            _show_help()
    except Exception as exc:
        emit_error(f"Clean command failed: {exc}")

    return True


# ---------------------------------------------------------------------------
# Help callback
# ---------------------------------------------------------------------------


def _custom_help() -> list[tuple[str, str]]:
    return [("clean", "Clean sessions, history, logs, and cache data")]


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

register_callback("custom_command", _handle_clean_command)
register_callback("custom_command_help", _custom_help)
