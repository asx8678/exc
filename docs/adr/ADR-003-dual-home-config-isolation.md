# ADR-003: Dual-Home Config Isolation for Elixir pup-ex

## Status

**ACCEPTED** (2026-04-19)

## Context

During the previous attempt to port configuration handling from Python pup to Elixir pup-ex,
Elixir code wrote directly into `~/.code_puppy/` — the Python pup's canonical home directory.
This corrupted Python pup's config, OAuth tokens, and session state for users running both
runtimes. Recovery required manual directory repair or deletion.

The root cause was **shared config home collision**: both Python and Elixir resolved the same
`~/.code_puppy/` path and operated on the same files without coordination. Elixir had no
awareness that it was a guest in another runtime's home.

This cannot happen again. A single directory under two runtimes with different serialization
formats, different write patterns, and different lifecycle expectations is a recipe for silent
data loss.

## Decision

Elixir pup-ex gets its own isolated home directory at `~/.code_puppy_ex/`. It must **never**
write to `~/.code_puppy/` under any circumstances. Isolation is enforced at the code level via
guard wrappers — not just policy or convention.

Key design choices (user-approved):

- **Home path**: `~/.code_puppy_ex/` — separate directory tree, no overlap
- **Env var**: `PUP_EX_HOME` — new variable, NOT reusing `PUP_HOME` (which controls Python)
- **OAuth**: re-authenticate separately; no token sharing between runtimes
- **Python is frozen** — no changes to Python's config resolution

## Path Resolution Precedence

Elixir pup-ex resolves its home directory in this order:

| Priority | Source | Behavior |
|----------|--------|----------|
| 1 (highest) | `PUP_EX_HOME` env var | Explicit override. If set, this IS the home. Period. |
| 2 | XDG vars | When `PUP_EX_HOME` is set, XDG vars are ignored (the env var IS the home). Otherwise, XDG vars resolve independently: `<XDG value>/code_puppy_ex` (e.g., `XDG_CONFIG_HOME=~/.config` → `~/.config/code_puppy_ex`). |
| 3 (default) | `~/.code_puppy_ex/` | Used when no env var is set. Created on first run if absent. |
| 4 (legacy) | `~/.code_puppy/` | **READ-ONLY** via explicit import flow only. Never a write target. Never auto-resolved as home. |

> **Important**: When `PUP_EX_HOME` is set, it takes total precedence and XDG vars are not
> consulted for directory resolution. When no `PUP_EX_HOME` is set but an XDG var is present,
> the path resolves to `<XDG value>/code_puppy_ex` (e.g., `XDG_CONFIG_HOME=~/.config` yields
> `~/.config/code_puppy_ex`), which may be outside `~/.code_puppy_ex/`. When no XDG var is
> set, all directories default under `~/.code_puppy_ex/`.

## Import Allowlist

When a user runs `mix pup_ex.import`, Elixir MAY copy files from the legacy home. This is
**opt-in only** — no automatic import on startup, no background sync.

### ✅ Allowed Imports

| File / Directory | Notes |
|-----------------|-------|
| `extra_models.json` | User-added model definitions |
| `models.json` (user additions) | Model registry entries; merge semantics TBD in Phase 3 |
| `puppy.cfg` (UI prefs only) | Extract `[ui]` section; ignore sections with paths/secrets |
| `agents/` | Agent definition files |
| `skills/` | Skill definition files |

### ❌ Forbidden Imports

| File / Directory | Reason |
|-----------------|--------|
| OAuth tokens (`oauth_*.json`, `*_token`) | Cross-runtime auth is a security violation |
| Active sessions (`sessions/`) | Runtime-specific state; sharing causes conflicts |
| Cookies / API keys | Credential leakage across process boundaries |
| `dbos_store.sqlite` | Internal Python state; binary format incompatible |
| `command_history.txt` | Runtime-specific history |
| Any file not in the allowlist above | Default-deny; explicit opt-in required |

The import task **copies** files; it does not move or symlink them. The legacy home remains
untouched.

## Guard Semantics

Isolation is enforced at the code level via a dedicated module: `CodePuppyControl.Config.Isolation`.

### Exception

```elixir
raise ConfigIsolationViolation, path: resolved_path, stacktrace: __STACKTRACE__
```

Every attempted write to the **legacy home** (`~/.code_puppy/`) via the `safe_*` wrappers
raises this exception with the full resolved path and stacktrace. Writes to paths
outside the Elixir home that are *not* under the legacy home (e.g., `/tmp`) are **not
blocked** — the guard protects against legacy-home collision, not general filesystem
sandboxing. There is no warning-level bypass. There is no config flag to disable it.
The guard is always active.

### Safe Wrappers

New and guarded config write paths in Elixir pup-ex MUST go through these wrappers:

| Wrapper | Purpose |
|---------|---------|
| `safe_write!(path, content)` | Write a file; raises `IsolationViolation` if target is under legacy home |
| `safe_mkdir_p!(path)` | Create directory tree; raises `IsolationViolation` if target is under legacy home |
| `safe_rm!(path)` | Remove a file; raises `IsolationViolation` if target is under legacy home |
| `safe_rm_rf!(path)` | Recursive delete; raises `IsolationViolation` if target is under legacy home |

Direct use of `File.write!/2`, `File.mkdir_p!/1`, `File.rm!/1`, or `File.rm_rf!/1` on
config paths is a **violation of this ADR** and will be caught in code review. **Caveat:**
~8 hardcoded `File.*` references still bypass the `safe_*` API (see [Known Hardcoded Violations](#known-hardcoded-violations)).
These are tracked for Phase 2 cleanup and represent known gaps in the isolation guarantee;
no new direct `File.*` calls on config paths should be added.

### Canonical Path Resolution

Before any guard check, paths are resolved through **canonical path resolution**:

1. `Path.expand/1` — expands `~`, `..`, env vars
2. `:file.read_link_info/1` — follows symlinks to their targets
3. Compare resolved path against **legacy home** prefix (`~/.code_puppy/`)

This blocks symlink attacks where `~/.code_puppy_ex/data → ~/.code_puppy/data` would bypass
the guard. The check happens *after* resolution, against the real path.

### Test Sandbox

Tests that intentionally need to write to arbitrary paths use:

```elixir
with_sandbox(paths, fun)
```

This stores a per-test whitelist in the process dictionary (`Process.put(:isolation_sandbox, paths)`)
and temporarily lifts the guard for the specified paths. When the fun completes, the sandbox
is cleared. No test-level flag leaks between processes or test runs.

### Telemetry

Every blocked violation emits a telemetry event:

```elixir
:telemetry.execute(
  [:code_puppy_control, :config, :isolation_violation],
  %{count: 1},
  %{path: resolved_path, action: action, process: self()}
)
```

This enables observability in production — operators can set alerts on this event without
needing to parse logs.

## Legacy Env Var Handling

The Python pup's env vars continue to work as before. They are **not adopted as the primary Elixir env var**; `PUP_EX_HOME` is the canonical variable for Elixir isolation. `PUP_HOME` takes precedence over `PUPPY_HOME` when both are set (PUP_HOME is the newer deprecated name). They will be removed in a future release.

| Env Var | Scope | Behavior |
|---------|-------|----------|
| `PUP_HOME` | Python pup (deprecated) | Overrides Python home directory. Takes precedence over `PUPPY_HOME`. |
| `PUPPY_HOME` | Python pup (legacy deprecated) | Same as `PUP_HOME` but older name. Used only when `PUP_HOME` is not set. |
| `PUP_EX_HOME` | Elixir pup-ex | **New.** Overrides Elixir's home directory. This is the preferred var for isolation. |

> **Why not reuse `PUP_HOME`?** Because `PUP_HOME` controls *which runtime's home* to use, and
> the two runtimes have different directory structures. Setting `PUP_HOME=~/.code_puppy_ex/`
> would break Python pup. Setting `PUP_EX_HOME=~/.code_puppy_ex/` is unambiguous.

### Read-Only Legacy Access

`Paths.legacy_home_dir/0` exposes `~/.code_puppy/` for import contexts **only**. Any use of
this function outside the import task is a code review violation. The function is documented
with `@doc legacy: true, read_only: true` and triggers a compiler warning if used in write
contexts (enforced via custom credo check in Phase 2).

## Mix Task Naming

Mix tasks use underscores (hyphens are invalid in Elixir module names):

| User-Facing Command | Mix Task | Purpose |
|---------------------|----------|---------|
| `pup-ex import` | `mix pup_ex.import` | One-time config import from legacy home |
| `pup-ex doctor` | `mix pup_ex.doctor` | Health check for Elixir home setup |
| `pup-ex auth login` | `mix pup_ex.auth.login` | Separate OAuth flow for Elixir runtime |

> **Note:** The binary wrapper (`pup-ex`) handles the UX translation from `pup-ex import`
> to `mix pup_ex.import`. This is tracked in Phase 6 of the overall plan.

## CI Gates

Five gates must pass before this ADR is considered implemented. All five are required for
acceptance — no partial credit.

| Gate | Name | Test | Rationale |
|------|------|------|-----------|
| GATE-1 | **No-write** | Full test suite with fake HOME where only `~/.code_puppy/` exists. After all tests complete, zero bytes have been written to `~/.code_puppy/`. | Proves isolation under realistic load. |
| GATE-2 | **Guard raises** | Direct call to `safe_write!("~/.code_puppy/any_file", "data")` raises `ConfigIsolationViolation`. | Proves the guard catches explicit violations. |
| GATE-3 | **Import is opt-in** | Start app with legacy home present and populated. App does NOT auto-copy any files. | Proves no silent side-effects on startup. |
| GATE-4 | **Doctor passes** | `mix pup_ex.doctor` on a freshly initialized `~/.code_puppy_ex/` returns ✅ with no warnings. | Proves the new home is self-sufficient. |
| GATE-5 | **Paths audit** | Every `Paths.*_dir/0` and `*_file/0` function never resolves under the legacy home. When XDG vars are set without `PUP_EX_HOME`, paths may resolve to `<XDG value>/code_puppy_ex`. | Proves path routing is complete. |

## Consequences

### Positive

- **Cannot accidentally damage Python pup.** The guard is code-level, not policy-level.
- **5 downstream issues unblocked:** all depend on Elixir
  having its own config home.
- **Enforcement is structural.** New developers cannot accidentally bypass isolation — the
  safe wrappers are the only path to file mutation.
- **Observability.** Telemetry events and `mix pup_ex.doctor` make violations visible.

### Negative

- **Users with existing `~/.code_puppy/` must run `pup-ex import` once.** This is a one-time
  migration step. It is documented in getting-started and the doctor task reminds users.
- **Some tests need sandbox opt-in.** Tests that write to arbitrary paths must use
  `with_sandbox/2`. This is a small ergonomics cost for a significant safety gain.

### Neutral

- **~10 hardcoded paths need routing through the Paths module.** This is tech debt that should
  have been fixed earlier. The isolation work forces the cleanup, which is a bonus.
- **The import allowlist may grow.** Future file types may need importing; the allowlist is
  extensible but changes require ADR amendment.

## Known Hardcoded Violations

The following files contain hardcoded paths that resolve to `~/.code_puppy/` instead of going
through the Paths module. These will be fixed in Phase 2 (Task 2.3) and are tracked here so
this ADR serves as the authoritative list.

| File | Line(s) | Description |
|------|---------|-------------|
| `lib/code_puppy_control/model_packs.ex` | 194 | Model pack storage path |
| `lib/code_puppy_control/model_registry.ex` | 359 | Model registry file path |
| `lib/code_puppy_control/plugins/loader.ex` | 33 | Plugin discovery directory |
| `lib/code_puppy_control/policy_config.ex` | 46 | Policy config file path |
| `lib/code_puppy_control/policy_engine.ex` | 569 | Policy engine data path |
| `lib/code_puppy_control/tools/skills.ex` | 76, 241 | Skills directory paths |
| `lib/code_puppy_control/tools/universal_constructor/create_action.ex` | 15 | Create action template path |
| `lib/code_puppy_control/tools/universal_constructor/registry.ex` | 40 | Registry storage path |

> **Total: 8 files, ~10 path references.** All will be migrated to use `Paths.*_dir/0` or
> `Paths.*_file/0` calls in Phase 2. No new hardcoded paths should be added after this ADR
> is accepted — code review should catch them.

## References

- Dual-home config isolation (this issue)
- Python policy freeze — Python config is frozen, no changes allowed
- Downstream: unblocked by dual-home isolation
- Binary wrapper UX (`pup-ex` CLI command)
- [ADR-001](ADR-001-elixir-python-worker-protocol.md) — Elixir ↔ Python worker protocol
- [ADR-002](ADR-002-python-elixir-event-protocol.md) — Python ↔ Elixir event protocol
