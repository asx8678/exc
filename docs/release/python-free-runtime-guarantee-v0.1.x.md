# Python-Free Runtime Guarantee — v0.1.x Audit Report

**Date:** 2026-05-04  
**Issue:** code-puppy-4ry  
**Auditors:** 10 parallel read-only audits (planning-agent-7971f2)

---

## Verdict

**Elixir-first / Python-optional for default CLI paths, NOT globally Python-free.**

The default Elixir CLI and REPL paths can start and operate without Python installed or configured. However, several production features still require a Python worker process. This is the first focused implementation pass to unblock default prod startup from the Python worker config requirement and harden error handling.

---

## What Is Python-Free (No Python Required)

| Path / Feature | Notes |
|---|---|
| `pup --help`, `pup --version` | Fast-path past validation via `cli_help_or_version_flag?/1` |
| REPL startup and prompt loop | Full agent conversation, LLM provider calls |
| Model registry, model settings | Config reads/writes via INI parser |
| LLM provider calls (Anthropic, OpenAI, etc.) | HTTP streaming, SSE chunk handling |
| File operations (list, read, grep) | Pure Elixir `FileOps` module |
| Parsing / indexer (Elixir, Erllang, Python, JS, TS, Rust) | Pure Elixir leex/yecc parsers under `Parsing.Parser` |
| Session storage / autosave | Ecto/SQLite, `Sessions` module |
| Event bus, event store | GenServer + ETS |
| Admin UI (dashboard, sessions, packs) | Phoenix LiveView — except run endpoints |
| Plugin system | Loader, callback registry |
| Policy engine, feature flags | Pure Elixir |
| CLI slash commands | `/agents`, `/model`, `/session`, `/diff`, `/flags`, etc. |
| TUI (chat, config, help screens) | Owl-based terminal UI |
| Scheduler (cron, tasks) | Oban-backed |
| MCP client/server | JSON-RPC over stdio/TLS |

## What Remains Python-Required

| Path / Feature | Module | Impact |
|---|---|---|
| `PythonWorker.Port` | `CodePuppyControl.PythonWorker.Port` | Direct `python3` subprocess; `Port.open` spawn (only used in bridge mode now) |
| `/api/runs/:id/execute` | `RunController` | Routes through `Run.Manager.execute_tool/4` → executor boundary (code-puppy-zyh) |
| Python bridge mode (`PUP_RUNTIME=python`) | `RuntimeSelector` | Routes all capabilities to Python bridge |
| Legacy Python package (`pup` CLI) | Python codebase | Separate entrypoint |

> **Note (code-puppy-96g):** `Run.Manager.start_run/3` no longer directly
> calls `PythonWorker.Supervisor.start_worker/2`.  It now routes through
> `Run.Executor`, which selects the Elixir-native executor by default
> (no Python required).  Only `PUP_RUNTIME=python` activates the Python
> executor backend.  `Run.State.cancel/2` and `Run.State` inactivity
> cleanup also route through the executor boundary.

---

## Fixes Implemented in This Pass (code-puppy-4ry)

### 1. Optional Python Worker Script in Prod Config

**Before:** `Config.validate!/0` always required `PUP_PYTHON_WORKER_SCRIPT` in prod, causing startup failure if unset.

**After:** `Config.validate!/0` only requires the Python worker script when `PUP_RUNTIME=python` (explicit Python bridge mode). In the default Elixir-first runtime (`:auto` or `:elixir` mode, or unset `PUP_RUNTIME`), the script is optional and `python_worker_script/0` returns `nil` when not configured.

- `Config.python_worker_script/0` now returns `String.t() | nil`
- New `Config.python_runtime?/0` helper checks `PUP_RUNTIME=python`
- `Config.load_from_env/0` omits `:python_worker_script` from the keyword list when nil
- `runtime.exs` tolerates nil script path; only configures app env when set

### 2. Graceful PythonWorker Error Tuples

**Before:** `PythonWorker.Port.init/1` would `raise` if the script path was missing, and `Port.open({:spawn_executable, "python3"}, ...)` could crash opaquely if `python3` wasn't found.

**After:**
- `init/1` returns `{:stop, {:python_worker_script_not_configured, message}}` when no script path is configured
- `init/1` returns `{:stop, {:python_unavailable, message}}` when `python3` is not on PATH
- `init/1` returns `{:stop, {:python_worker_spawn_failed, message}}` if `Port.open` itself raises
- These propagate cleanly through `DynamicSupervisor.start_child/2` as `{:error, reason}` tuples instead of process crashes

### 3. Targeted Tests

New test file `test/code_puppy_control/python_free_runtime_test.exs` with `async: false` covering:
- `Config.python_worker_script/0` returns nil when unset, returns value from app env / env vars
- `Config.python_runtime?/0` reflects `PUP_RUNTIME` state
- `Config.validate!/0` succeeds in prod without Python worker script (Elixir-first)
- `Config.validate!/0` fails with clear message when `PUP_RUNTIME=python` and script missing
- `PythonWorker.Port.init/1` returns graceful error tuples
- `Config.load_from_env/0` omits nil script path

Updated existing integration test for missing script path (from raise to error tuple).

---

## Follow-Up Issues Required

| ID | Issue | Priority | Notes |
|---|---|---|---|
| A | Refactor `Run.Manager` behind Elixir/Python executor boundary | ✓ Done (code-puppy-96g) | `start_run/3` routes through `Run.Executor` facade; Elixir executor is default |
| B | ~~Refactor `/api/runs/:id/execute` away from direct `PythonWorker.Port`~~ | P1/P2 | **Done** — Controller now routes through `Run.Manager.execute_tool/4` → executor boundary (code-puppy-zyh) |
| C | Add packaged no-Python smoke to release gate/CI | ✓ Done (code-puppy-osy) | `mix pup_ex.smoke --no-python` + CI workflow steps added |
| D | Update README/architecture docs from Python-first to Elixir-first/Python-optional | P2 | Current docs imply Python is always required |
| E | Remove/guard Python CLI fallback from release overlay wrappers | P2 | Shell wrappers in `rel/` may still try `python3 pup` |
| F | Resolve Python `pup` entrypoint collision / version stream | P2/P3 | Both Python and Elixir provide a `pup` command; need clear separation or deprecation path |

---

## Environment Variable Reference

| Variable | Required? | Default | Notes |
|---|---|---|---|
| `PUP_RUNTIME` | No | `auto` (Elixir-first) | Set to `python` to require Python bridge |
| `PUP_PYTHON_WORKER_SCRIPT` | Conditional | `nil` | Required only when `PUP_RUNTIME=python` |
| `PYTHON_WORKER_SCRIPT` | Conditional (legacy) | `nil` | Deprecated; same semantics as above |
| `PUP_SECRET_KEY_BASE` | Yes (prod) | Auto-generated (Burrito) | Phoenix endpoint secret |
| `PUP_DATABASE_PATH` | Yes (prod) | Auto-defaulted (Burrito) | SQLite database path |
