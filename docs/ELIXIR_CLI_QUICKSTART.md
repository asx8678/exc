# Elixir CLI Quickstart & Dogfood Guide

> 🐶 **Primary daily-driver** — The **Burrito native binary** (`code_puppy_control_<target>`) is the recommended install: fully self-contained, no Erlang/Elixir/Python on the target machine, and includes the complete OTP release (Repo/Oban/Phoenix Endpoint). The `./pup` escript is available for dev/smoke testing but is a **degraded** runtime (no database, scheduler, or admin UI). Python is optional and only needed for explicit bridge-worker or legacy Python CLI flows (see [Python bridge-worker mode](#python-bridge-worker-mode)).
>
> ⚠️ **Command-name collision:** the Python `codepp` package also installs a legacy `pup` alias next to its canonical Python/PyPI `code-puppy` command. This guide uses `./pup` for the Elixir escript when ambiguity matters. If bare `pup` runs the Python CLI, call the Elixir binary by path or adjust `PATH`. Version streams are separate: Python/PyPI is `0.0.x` from `pyproject.toml`; Elixir-native is `0.1.x` from `mix.exs`. There is no generated `pup-ex` executable; `pup_ex` names Mix tasks.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Setup](#2-setup)
3. [Isolation & Home Directory](#3-isolation-home-directory)
4. [Credentials](#4-credentials)
5. [No-Network Smoke (`mix pup_ex.smoke`)](#5-no-network-smoke-mix-pup_exsmoke)
6. [Escript Build](#6-escript-build)
7. [CLI Usage](#7-cli-usage)
8. [Troubleshooting & Known Caveats](#8-troubleshooting-known-caveats)

---

## 1. Prerequisites

| Requirement | Minimum |
|-------------|---------|
| Elixir | ~> 1.15 |
| Erlang/OTP | 26+ |
| Zig (optional) | Any — for Burrito single-binary builds |

Install Elixir/Erlang via `asdf`, `brew`, or your preferred version manager, then:

```bash
cd elixir/code_puppy_control
mix deps.get
```

## 2. Setup

### First-time initialization

If you have an existing Python pup home at `~/.code_puppy/`, import your non-sensitive settings:

```bash
# Dry-run: see what would be copied
mix pup_ex.import

# Actually copy
mix pup_ex.import --confirm

# Overwrite existing files
mix pup_ex.import --confirm --force
```

**What gets imported:** `extra_models.json`, `models.json` (user additions), `[ui]` section of `puppy.cfg`, `agents/`, `skills/`.

**What never gets imported:** OAuth tokens, API keys, sessions, autosaves, `*.sqlite`, `command_history.txt`. See [ADR-003](adr/ADR-003-dual-home-config-isolation.md) for the full allowlist.

### Verify health

```bash
mix pup_ex.doctor
```

Expected output ends with `Status: ISOLATED ✅`. If you see warnings, check [Troubleshooting](#8-troubleshooting-known-caveats) below.

## 3. Isolation & Home Directory

The Elixir runtime (`./pup` CLI and `pup_ex` Mix tasks) uses a **separate home** from the Python compatibility package to prevent config corruption (see [ADR-003](adr/ADR-003-dual-home-config-isolation.md)):

| Runtime | Home Directory | Access |
|---------|---------------|--------|
| Elixir `./pup` / `pup_ex` tasks | `~/.code_puppy_ex/` (or `PUP_EX_HOME`) | Read + write |
| Python `code-puppy` / legacy `pup` | `~/.code_puppy/` | Read-only via import |

### Environment variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `PUP_EX_HOME` | Override Elixir home | `~/.code_puppy_ex/` |
| `PUP_RUNTIME` | Force runtime selector (`auto`, `elixir`, or `python`); set to `python` to activate bridge-worker mode; set to `elixir` to run without Python (**this is the canonical no-Python flag** — no separate `PUP_NO_PYTHON` env var exists) | `auto` (Elixir-first) |
| `PUP_PYTHON_WORKER_SCRIPT` | Path to the Python worker script used by the Elixir bridge; required only for explicit `PUP_RUNTIME=python` / `--bridge-mode` flows | — |
| `PUP_HOME` | Deprecated — logs warning | — |
| `PUPPY_HOME` | Legacy — logs warning | — |

> **Use `PUP_EX_HOME` for Elixir.** `PUP_RUNTIME` controls which runtime backend the CLI selects at session start. `PUP_HOME`/`PUPPY_HOME` are deprecated fallbacks honoured by both Python and Elixir (Elixir logs a deprecation warning). They will be removed in a future release.
>
> New runtime env vars use the `PUP_` prefix per project convention. Legacy `PUPPY_`-prefixed vars are deprecated but still supported.

### Directory layout

```
~/.code_puppy_ex/
├── puppy.cfg              # Main config (INI format)
├── mcp_servers.json       # MCP server definitions
├── models.json            # Model registry
├── extra_models.json      # User-added models
├── chatgpt_models.json    # ChatGPT OAuth models
├── claude_models.json     # Claude Code OAuth models
├── model_packs.json       # Model pack definitions
├── agents/                # Agent definitions
├── skills/                # Skill definitions
├── credentials/           # AES-256-GCM encrypted store
├── auth/                  # OAuth scaffolding (placeholder)
├── plugins/               # User plugins
├── autosaves/             # Session autosaves
├── command_history.txt    # REPL command history
└── policy.json            # User-level policy rules
```

### Isolation enforcement

New and guarded config write paths use `CodePuppyControl.Config.Isolation` safe wrappers (`safe_write!`, `safe_mkdir_p!`, `safe_rm!`, `safe_rm_rf!`). Any attempt to write under `~/.code_puppy/` via these wrappers raises `IsolationViolation`. Symlink attacks are blocked via canonical path resolution. **Caveat:** ~8 hardcoded `File.*` path references still bypass the `safe_*` API (tracked in ADR-003 Known Hardcoded Violations for Phase 2 cleanup). The isolation guarantee covers code using the `safe_*` API, not every possible I/O path in the codebase.

## 4. Credentials

API keys and tokens are stored in an AES-256-GCM encrypted file at `~/.code_puppy_ex/credentials/store.json`. Encryption keys are derived from a persistent random secret stored at `~/.code_puppy_ex/.machine_secret` (32 bytes, created on first use with `0o600` permissions). Credentials are not portable across machines because each installation generates its own secret. (The secret path is overridable via `PUP_MACHINE_SECRET_PATH`.)

### Mix tasks

```bash
# Interactive — prompts for value (preferred)
mix pup_ex.auth.set OPENAI_API_KEY

# Non-interactive — value on command line (may leak to shell history)
mix pup_ex.auth.set ANTHROPIC_API_KEY sk-ant-...

# From environment variable — useful for CI
mix pup_ex.auth.set OPENAI_API_KEY --from-env MY_OPENAI_KEY

# List stored key names (values are never printed)
mix pup_ex.auth.list

# Delete a credential (idempotent)
mix pup_ex.auth.delete OPENAI_API_KEY
```

### OAuth

```bash
mix pup_ex.auth.login
```

This creates the `~/.code_puppy_ex/auth/` directory scaffolding. Full OAuth PKCE flow is not yet implemented — re-run when available. Elixir pup-ex **never** reads credentials from Python's `~/.code_puppy/auth/`.

### Import from Python

API keys from Python's `puppy.cfg` can be imported programmatically:

```elixir
{:ok, count} = CodePuppyControl.Credentials.import_from_python()
```

This reads only API key names recognized from Python's config format. It does not import OAuth tokens.

## 5. No-Network Smoke (`mix pup_ex.smoke`)

The dogfood smoke suite exercises the CLI's most fragile junctions — argv parsing, run-mode routing, sandboxed config/session, and the one-shot prompt path — without making real API calls or touching your real home directory.

### Default run (fast, no network)

```bash
mix pup_ex.smoke
```

Output:

```
🐶 pup-ex smoke — no-network dogfood (168 ms)
  sandbox: /tmp/pup_smoke_.../.code_puppy_ex (cleaned up)

  [ok] parser — argv parsing + help text invariants ok
  [ok] run_mode — run-mode resolver routes all known inputs
  [ok] sandbox — sandbox isolated; PUP_EX_HOME=...
  [ok] one_shot — OneShot.run/1 dispatched to MockLLM and rendered canned reply

SMOKE PASS — all phases ok
```

### Phases

| Phase | What it checks |
|-------|---------------|
| `parser` | `Parser.parse/1` returns expected tags for `--help`, `--version`, valid args, invalid args; help text invariants |
| `run_mode` | `CLI.resolve_run_mode/1` routes correctly without side effects |
| `sandbox` | `Paths.home_dir/0` resolves under the tmp sandbox, not the real home |
| `one_shot` | `OneShot.run/1` succeeds end-to-end with `Smoke.MockLLM`, persists messages into the sandbox |
| `escript` | **Opt-in** — spawns the built `pup` escript with `--version`, asserts exit 0 + version marker |

### Options

```bash
mix pup_ex.smoke                        # default phases (parser, run_mode, sandbox, one_shot)
mix pup_ex.smoke --escript              # also run the escript phase
mix pup_ex.smoke --phase parser         # run only the parser phase
mix pup_ex.smoke --phase parser --phase run_mode  # run specific phases
mix pup_ex.smoke --json                 # emit JSON report (machine-parseable)
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All phases passed (or were deliberately skipped) |
| 1 | At least one phase failed |
| 2 | Invalid arguments to the Mix task |

### Determinism guarantees

1. `PUP_EX_HOME` is set to a unique tmp directory before any `Paths.*` call.
2. `PUP_TEST_SESSION_ROOT` and `PUP_SESSION_DIR` are redirected to the sandbox.
3. `Smoke.MockLLM` is injected via `:repl_llm_module` Application env for the duration of the one-shot phase.
4. On teardown, every snapshotted env value is restored and the sandbox is `rm_rf`'d. Your real `~/.code_puppy_ex/` is left untouched.

### Why a Mix task, not a runtime command?

The smoke suite needs to set sandbox env vars **before** the OTP application starts. Only a Mix task wrapping the boot sequence can do this reliably. Run it before daily-driver use — it's cheap and deterministic.

## 6. Escript Build

The `pup` escript is a self-contained CLI binary that requires only the Erlang runtime on the target machine (no Elixir install needed). It is suitable for **local development and smoke testing**, but is a **degraded runtime** — it lacks Repo/Oban/Phoenix Endpoint (no database, scheduler, or admin UI). For real work, prefer the Burrito binary (see below).

### Build

```bash
MIX_ENV=prod mix escript.build
```

Produces `./pup` in the Elixir project root. This is the Elixir-native `pup`, not the Python `codepp` legacy alias.

### Verify

```bash
./pup --version
# output: code-puppy 0.1.0

# Also exercise via smoke escript phase
mix pup_ex.smoke --escript
```

### Burrito native binary (recommended daily-driver)

The Burrito binary is the **recommended production runtime** — a fully self-contained executable with no Erlang/Elixir/Python required on the target machine. It includes the complete OTP release (Repo/Oban/Phoenix Endpoint), providing database, scheduler, admin UI, and all production services that the escript lacks.

```bash
scripts/build-burrito.sh
```

Requires Zig on PATH. See [docs/burrito-release.md](../elixir/code_puppy_control/docs/burrito-release.md) for the platform matrix and prerequisites.

Pre-built Burrito binaries are published to [GitHub Releases](https://github.com/mpfaffenberger/code_puppy/releases) for each tagged Elixir release.

**Runtime comparison:**

| Feature | Burrito binary | Escript `./pup` |
|---------|---------------|------------------|
| Self-contained (no Erlang install) | ✅ Yes | ❌ Needs Erlang/OTP |
| Repo (Ecto/SQLite database) | ✅ Yes | ❌ No |
| Oban (scheduler) | ✅ Yes | ❌ No |
| Phoenix Endpoint (admin UI) | ✅ Yes | ❌ No |
| Production ready | ✅ Recommended | ⚠️ Dev/smoke only |
| Python-free by default | ✅ `PUP_RUNTIME=elixir` | ✅ `PUP_RUNTIME=elixir` |

## 7. CLI Usage

### `pup` command reference

This section describes the **Elixir escript** built as `./pup` from `elixir/code_puppy_control`. If your shell resolves bare `pup` to the installed Python `codepp` console script instead, use `./pup` or the packaged Elixir binary path. Within the Python/PyPI package, `pup` is the legacy alias and `code-puppy` is canonical.

```
Usage: pup [OPTIONS] [PROMPT]

Options:
  -h, --help            Show help and exit
  -v, -V, --version     Show version and exit
  -m, --model MODEL     Model to use (default: from config)
  -a, --agent AGENT     Agent to use (default: code-puppy)
  -c, --continue        Resume the most recent persisted session, then enter interactive mode
  -p, --prompt PROMPT   Execute a single prompt and exit
  -i, --interactive     Run in interactive mode
  --bridge-mode         Force Python runtime (sets PUP_RUNTIME=python for the session)
```

### Running without Python (default)

> **No Python is required by default.** The Burrito binary and escript run fully on the BEAM VM. Simply launch `./pup` — `PUP_RUNTIME` defaults to `auto` (Elixir-first).
> To explicitly guarantee no Python is invoked, set `PUP_RUNTIME=elixir`. There is no separate `PUP_NO_PYTHON` env var; `PUP_RUNTIME=elixir` is the canonical no-Python selector.

```bash
# Default: no Python needed
./pup

# Explicitly guarantee no Python
PUP_RUNTIME=elixir ./pup
```

### Python bridge-worker mode (optional)

> **Python is optional.** The bridge-worker mode exists for legacy Python CLI interoperability and for capabilities not yet ported to Elixir.

When `PUP_RUNTIME=python` or `--bridge-mode` is passed, the Elixir CLI delegates capability execution to a Python process running as a JSON-RPC bridge worker. In production bridge mode, configure `PUP_PYTHON_WORKER_SCRIPT` if the worker script cannot be discovered from the installed `codepp` package. The default Elixir runtime never needs this variable.

```bash
# Elixir CLI with explicit Python bridge
./pup --bridge-mode

# Or via environment variable
PUP_RUNTIME=python ./pup

# Python standalone bridge worker (legacy direct invocation)
python -m code_puppy --bridge-mode
```

In Python bridge-worker mode:

- `cli_runner.main_entry()` sets `CODE_PUPPY_BRIDGE=1` before importing the full app runtime, so the bridge plugin sees `BRIDGE_ENABLED=True` during import-time callback registration.
- stdout is reserved for Content-Length-framed JSON-RPC messages only. Logos, Rich/Owl/Textual renderers, first-run config onboarding, version-status chatter, GIL status, REPL startup, and DBOS startup are skipped to keep the wire protocol clean.
- startup callbacks create the bridge controller and emit a `bridge.ready` notification; `AppRunner._run_bridge_mode()` then keeps the asyncio loop alive until the controller handles an `exit` request and marks itself stopped.
- Current Python bridge control methods include `initialize`, `run.start`, `run.cancel`, `ping`, and `exit` (plus file/tool/concurrency methods exposed by the bridge controller). The older `worker.ping`/`worker.shutdown` names are not aliases in the Python bridge plugin.

### One-shot prompt (non-interactive)

Execute a single prompt and exit — ideal for scripting and CI:

```bash
# Via -p flag
./pup -p "explain this function"

# Positional (first non-flag argument becomes the prompt)
./pup "explain this function"

# With model and agent selection
./pup -m claude-sonnet -a code-reviewer "review this diff"
```

The one-shot path runs through the full dispatch pipeline (resolve agent → ensure state → append → dispatch → persist → autosave) and returns `:ok` on success, `:error` on failure. Exit code 0 for success, 1 for failure.

### Positional prompt

The first positional argument is treated as the prompt if `-p` is not given:

```bash
./pup "what does this code do?"        # equivalent to -p "what does this code do?"
./pup -i                              # interactive mode (same as bare ./pup)
./pup -m gpt-4o "refactor this"       # one-shot with model override
```

### Interactive mode

Start a REPL with slash commands, model/agent switching, and session management:

```bash
# Default interactive mode
./pup

# Interactive (note: -i with a positional prompt is parsed but not yet dispatched;
# use -p "help me debug this" for a single-shot prompt instead)
./pup -i

# Resume the newest persisted session, then enter interactive mode
./pup -c

# Equivalent long flags; --continue wins over --interactive during routing
./pup --interactive --continue

# With a different model
./pup -m claude-sonnet
```

#### Interactive slash commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/quit`, `/exit` | Exit the REPL |
| `/model [name]` | Interactive or direct model switch |
| `/agent [name]` | Interactive or direct agent switch |
| `/sessions` | Browse and switch sessions |
| `/tui` | Launch full TUI interface |
| `/clear` | Clear terminal screen |
| `/history` | Show command history |

## 8. Troubleshooting & Known Caveats

### Common issues

| Symptom | Fix |
|---------|-----|
| `mix pup_ex.doctor` shows failures | Re-run `mix pup_ex.import --confirm` to rebuild `~/.code_puppy_ex/` |
| `IsolationViolation` at runtime | Code using `Isolation.safe_*` wrappers attempted to write to the legacy home directory (`~/.code_puppy/`). The wrappers block legacy-home writes to prevent cross-runtime collision; they do not enforce a general filesystem sandbox (writes to other non-legacy paths are allowed). |
| `database is locked` in smoke | Harmless — multiple SQLite pool connections race during the short-lived smoke app start. Does not affect smoke results. |
| Escript `--version` shows wrong version | Rebuild: `MIX_ENV=prod mix escript.build` |
| `PUP_HOME` deprecation warnings | Switch to `PUP_EX_HOME`. `PUP_HOME`/`PUPPY_HOME` are deprecated fallbacks used by both Python and Elixir; they will be removed in a future release. |
| OAuth flow not available | `mix pup_ex.auth.login` currently only creates directory scaffolding. Use `mix pup_ex.auth.set` for API keys in the meantime. |
| Credentials not portable across machines | By design — AES-256-GCM key is derived from a per-installation random secret at `~/.code_puppy_ex/.machine_secret`. Re-enter credentials on each machine. |

### Known caveats

- **Phoenix API parity is incomplete.** The Phoenix control plane still references Python workers for some operations. Do not assume full Elixir-only server parity.
- **`mix pup_ex.auth.login` is scaffolding only.** Full OAuth PKCE flow (ChatGPT, Claude) is not yet implemented.
- **SQLite lock warnings in smoke.** The smoke task starts the full OTP app briefly; multiple SQLite pool connections may log `database is locked` errors. These are cosmetic and do not affect smoke results.
- **~8 hardcoded path references** still resolve outside `Paths.*` — tracked in ADR-003, scheduled for Phase 2 cleanup. No new hardcoded paths should be added.
- **`--bridge-mode` in the Elixir CLI** sets `PUP_RUNTIME=python` for the session, forcing the Elixir CLI to delegate capabilities to the Python bridge runtime (see `RuntimeSelector`, code_puppy-bwt). This is distinct from the Python CLI's `--bridge-mode`, which sets `CODE_PUPPY_BRIDGE=1` and runs the Python process as a JSON-RPC bridge worker over stdio for Elixir orchestration.
- **First-run marker.** After setup, `mix pup_ex.doctor` may note "First-run marker — not initialized yet." This is informational and does not block usage.

### Running `mix pup_ex.smoke` in CI

```bash
# Human-readable (default)
mix pup_ex.smoke

# Machine-parseable JSON
mix pup_ex.smoke --json > smoke-report.json

# Include escript verification
MIX_ENV=prod mix escript.build && mix pup_ex.smoke --escript
```

The JSON schema is stable — `status`, `duration_ms`, `sandbox_dir`, and `phases[]` with `phase`/`status`/`detail`/`metrics` keys.

**Caveat:** Elixir Logger output may precede the JSON on stdout, so piping directly to `jq .` can fail. To parse reliably, strip Logger lines before `jq`:

```bash
# Strip Logger lines (match HH:MM:SS.mmm [level] prefix)
mix pup_ex.smoke --json 2>/dev/null | sed '/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/d' | jq .

# Or capture raw and strip when reading
mix pup_ex.smoke --json > smoke-report.json
sed '/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/d' smoke-report.json | jq .
```

---

*Refs: code_puppy-aod, code_puppy-baa*
