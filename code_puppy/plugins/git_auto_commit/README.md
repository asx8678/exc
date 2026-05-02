# Git Auto Commit (GAC) Plugin - BLK1 Spike

**Status:** ✅ **SPIKE COMPLETE** - Shell Security Path Proven

## What This Proves

This spike demonstrates that a `/commit` slash command can safely orchestrate async git commands through Code Puppy's centralized shell security boundary.

### The Challenge
- **Slash commands** use the `custom_command` callback hook (sync-triggered via `_trigger_callbacks_sync`)
- **Shell execution** goes through `SecurityBoundary.check_shell_command()` (async) → `run_shell_command` callbacks → subprocess
- **The problem:** `custom_command` is sync but shell execution is async
- **Additional issue:** `shell_safety` plugin uses `signal.alarm()` which only works in the main thread

### The Solution
The `shell_bridge.py` module uses an adaptive approach to bridge sync and async:

1. **Main thread detection**: Checks if we're in the main thread or a worker thread
2. **Async context detection**: Checks if an event loop is already running
3. **Adaptive execution**:
   - If in main thread (no running loop): Uses `asyncio.run()` which works with `signal.alarm()`
   - If in worker thread: Uses thread-based execution with signal compatibility fallback
   - If in async context: Returns clear error directing to use async version directly

This approach **preserves signal compatibility** with the `shell_safety` plugin while still providing a sync→async bridge.

## Architecture

```
User types: /commit status
    ↓
custom_command callback (SYNC - _trigger_callbacks_sync)
    ↓
_handle_commit_command() in register_callbacks.py
    ↓
execute_git_command_sync() in shell_bridge.py
    ↓
Adaptive execution:
    ├── Main thread: asyncio.run() → works with signal.alarm()
    ├── Worker thread: ThreadPoolExecutor with signal fallback
    └── Async context: Error (use async version directly)
    ↓
execute_git_command() (ASYNC)
    ↓
SecurityBoundary.check_shell_command() - security validation
    ↓
run_shell_command callbacks (async - shell_safety, etc.)
    ↓
asyncio.create_subprocess_shell() - actual execution
    ↓
Result propagates back up the chain
```

## Files

| File | Purpose |
|------|---------|
| `__init__.py` | Plugin initialization |
| `register_callbacks.py` | Registers `/commit` command and help text |
| `shell_bridge.py` | Sync→Async bridge for shell execution |
| `tests/plugins/test_gac_shell_bridge.py` | Comprehensive test suite |

## Usage

```
/commit              # Shows git status (default)
/commit status       # Shows git status
/commit branch       # Shows git branches
/commit log          # Shows git log
/commit diff         # Shows git diff
/commit show         # Shows git show
```

## Security

- All commands pass through `SecurityBoundary.check_shell_command()`
- PolicyEngine rules can block/allow specific commands
- `run_shell_command` callbacks (e.g., shell_safety) provide additional validation
- Subcommand whitelist: only `status`, `branch`, `log`, `diff`, `show` are allowed

## Test Results

All 27 tests pass:
- ✅ Sync→async bridge works without deadlock
- ✅ Security boundary integration functional
- ✅ Concurrent calls work safely
- ✅ Command execution successful

```bash
pytest tests/plugins/test_gac_shell_bridge.py -v
# 27 passed in ~3s
```

## What Works

1. **Signal-Aware Sync→Async Bridge**: `execute_git_command_sync()` adapts to the calling context:
   - Main thread: Uses `asyncio.run()` for signal compatibility with `shell_safety`
   - Worker threads: Uses thread-based execution with signal fallback
   - Async context: Clear error directing to use `execute_git_command()` directly
2. **Security Integration**: Commands properly validated by `SecurityBoundary`
3. **No Deadlocks**: Concurrent and sequential calls work reliably
4. **Full Flow**: `/commit` → handler → bridge → security → subprocess → result
5. **shell_safety Compatibility**: Works even when `shell_safety` plugin is loaded (uses `signal.alarm()`) in main thread

## What's Next (GAC Epic)

This spike unblocks the full Git Auto Commit epic:
1. Detect changed files (`git status --porcelain`)
2. Generate commit message via LLM
3. User confirmation
4. Execute `git add`, `git commit`
5. Handle edge cases (merge conflicts, detached HEAD, etc.)

## Commit Message

```
feat(gac): BLK1 spike - prove shell security path for /commit
```
