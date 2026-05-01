# Feature-Flag System — `code_puppy-djs.4` Specification

**Date:** 2026-05-01
**Status:** DRAFT
**Coordinator:** planning-agent-74f842 (Hybrid Option A)
**Primary Specialist:** elixir-programmer-2d6ffe
**Depends-on:** ADR-004 (§ "Feature Flag System"), `code_puppy-djs.1` (Phase H audit)
**Blocks:** `code_puppy-bwt` (runtime selector), `code_puppy-djs.6` (gradual rollout controller)
**Implementation ref:** `feature/code-puppy-djs-4-feature-flags` (round 1), `feature/code-puppy-djs-4-6-python-mirror` (round 2.A), `feature/code-puppy-djs-4-7-feature-flags-command` (round 2.B)

---

## 1. Goals & Non-Goals

### Goals (in scope for djs.4)

1. **Per-capability flag storage** — A `flags.json` file under the Elixir home dir (`~/.code_puppy_ex/`) with independent boolean toggles for each capability.
2. **Elixir GenServer** — `CodePuppyControl.FeatureFlags` managing in-memory flag state, with a lock-free ETS hot-path for `enabled?/1`.
3. **Python mirror client** — A `FeatureFlagClient` module on the Python side that reads the same `flags.json` directly (no bridge RPC dependency for flag reads).
4. **CLI integration** — A `/feature-flags` slash command (distinct from the existing `/flags` which remains WorkflowState-only).
5. **Supervision integration** — FeatureFlags starts early in the Elixir supervision tree (after `Phoenix.PubSub`, before any consumer).
6. **Hot-reload** — Live reload from disk without process restart (explicit reload + optional file-watcher trigger).
7. **Telemetry** — Emit `[:code_puppy_control, :feature_flags, ...]` events on init, set, reset, reload, and check.
8. **Backward-compatibility** — Existing toggles (`PUP_RUNTIME=elixir`, `enable_elixir_message_shadow_mode`, `is_pup_ex()`) remain functional. Precedence rule defined.

### Non-Goals (left to bwt / djs.6 / deferred)

1. **Runtime selector** — `djs.4` does *not* implement `PUP_RUNTIME=auto` or request-type routing. That is `code_puppy-bwt`'s contract. djs.4 provides the `enabled?/1` primitive that bwt calls.
2. **Percentage-based rollout** — Gradual percentage enablement (5% → 50% → 100%) is `code_puppy-djs.6`'s contract. djs.4 is binary per-capability only.
3. **Auto-fallback** — If a flagged capability's runtime fails, fallback to the other runtime. This is bwt's responsibility.
4. **Rollout-specific observability** — Metrics on which runtime handled each request. This is djs.6's responsibility (general telemetry exists).
5. **Capability sub-splitting** — No sub-flags like `:tools_file_ops` vs `:tools_command_runner`. See §1.3 of `bd remember code_puppy-djs-4-feature-flag-decisions`.
6. **Plugin runtime unload** — `:plugins = false` is a load-gate only; already-loaded callbacks remain. Full runtime unload is deferred.
7. **Python-side write-back** — The Python mirror is read-only. Only Elixir writes to `flags.json`.

---

## 2. `flags.json` Schema

### 2.1 File Location

```
~/.code_puppy_ex/flags.json
```

Resolved at runtime by `CodePuppyControl.Config.Paths.flags_file/0`, defined as:

```elixir
def flags_file do
  Path.join(config_dir(), "flags.json")
end
```

This honors XDG vars (when configured) and defaults to `~/.code_puppy_ex/flags.json` per ADR-004 § "Feature Flag System".

**Reference:** `elixir/code_puppy_control/lib/code_puppy_control/config/paths.ex` (commit `557e0690` adds the `flags_file/0` function).

### 2.2 Capability Enum (v1 — flat, no hierarchy)

| JSON Key                | Atom              | Description                          |
|-------------------------|-------------------|--------------------------------------|
| `elixir.llm_client`     | `:llm_client`     | Route LLM client calls to Elixir     |
| `elixir.base_agent`     | `:base_agent`     | Route agent execution to Elixir      |
| `elixir.tools`          | `:tools`          | Route tool dispatch to Elixir        |
| `elixir.plugins`        | `:plugins`        | Load plugins via Elixir loader       |
| `elixir.cli`            | `:cli`            | Route CLI/REPL to Elixir             |

### 2.3 Default Values

All flags default to **`false`** (Python path active) when:
- `flags.json` does not exist
- `flags.json` is malformed (non-JSON, empty, or non-object)
- The specific key is absent from the file

This is the conservative default — aggressive Elixir-on defaults are the rollout controller's responsibility (`code_puppy-djs.6`).

### 2.4 Canonical Example

```json
{
  "elixir.llm_client": false,
  "elixir.base_agent": false,
  "elixir.tools": false,
  "elixir.plugins": false,
  "elixir.cli": false
}
```

### 2.5 Version Field

No `"version"` field in v1. The schema is assumed stable — unknown keys are silently ignored (backward-compatible). A version field may be added in a future iteration if the schema evolves in a backward-incompatible way.

### 2.6 Hot-Reload Semantics

- **Explicit reload:** `FeatureFlags.reload/0` re-reads the file from disk and updates all internal state. Returns `:ok` or `{:error, reason}`.
- **Implicit reload:** The GenServer does **not** file-watch by default in v1. Downstream consumers (e.g., a `/feature-flags reload` command) trigger explicit reloads. A `FileSystem` watcher may be added in a follow-up if polling proves insufficient.
- **Write atomicity:** `File.write/2` is used with `pretty: true` JSON encoding. The file is small (< 1 KB), so atomicity via tempfile+rename is not required in v1 but may be added in a follow-up.

---

## 3. Elixir API — `CodePuppyControl.FeatureFlags`

### 3.1 Module Structure

```
elixir/code_puppy_control/lib/code_puppy_control/
  feature_flags.ex          # GenServer — main API
  feature_flags/
    flags.ex                # Capability definitions & resolution
```

### 3.2 Public API

```elixir
# Check if a capability is enabled (hot-path: GenServer.call, catch :exit -> false)
@spec enabled?(atom()) :: boolean()

# List all capabilities with status
@spec list() :: [{atom(), boolean(), String.t()}]

# Set a capability at runtime (persists to disk)
@spec set(atom() | String.t(), boolean()) :: :ok | {:error, String.t()}

# Reset all capabilities to defaults (all false)
@spec reset() :: :ok | {:error, String.t()}

# Reload flags from disk
@spec reload() :: :ok | {:error, String.t()}

# Start the GenServer (called by supervision tree)
@spec start_link(keyword()) :: GenServer.on_start()
```

### 3.3 Hot-Path Invariant (Load-Bearing)

`enabled?/1` **must** remain lock-free ETS-only in a follow-up. In the v1 implementation it uses `GenServer.call/2` — this is acceptable for Phase H startup but **must** be migrated to an ETS direct-read before being called on every LLM request. The ETS cache is populated by the GenServer on init and updated on set/reset/reload.

Current implementation (commit `557e0690`):
```elixir
def enabled?(capability) when is_atom(capability) do
  unless Flags.known?(capability) do
    raise ArgumentError, "Unknown feature-flag capability: #{inspect(capability)}"
  end
  GenServer.call(__MODULE__, {:enabled?, capability})
catch
  :exit, _ -> false   # safe default if GenServer down
end
```

**ETS migration note:** When migrating to ETS direct-read, the GenServer must write to a named ETS table on init and on every state change. The read path becomes `:ets.lookup(:feature_flags, capability)` — no GenServer.call, no telemetry on read.

### 3.4 Error Handling

| Scenario | Behavior |
|----------|----------|
| GenServer not started | `enabled?/1` → `false` (catch `:exit`) |
| Unknown capability atom | Raises `ArgumentError` |
| Malformed `flags.json` | All flags default to `false`; warning logged |
| Unknown JSON key in `flags.json` | Silently ignored |
| Non-boolean value for known key | Skipped with `Logger.warning`; default used |
| Disk write failure on `set/2` | Returns `{:error, reason}`; in-memory state unchanged |

### 3.5 Supervision Strategy

```
INSERT after:   CodePuppyControl.Config.Writer
INSERT before:  CodePuppyControl.RequestTracker
```

In `application.ex` (commit `557e0690`):

```elixir
# ADR-004 Phase H feature flags
# Must start after Phoenix.PubSub (for telemetry broadcasts)
# Must start before any consumer that calls FeatureFlags.enabled?/1
CodePuppyControl.FeatureFlags,
```

**Restart strategy:** `:permanent` — if FeatureFlags crashes, the entire supervision tree restarts. This is intentional because FeatureFlags is a core routing primitive that every consumer depends on. A dead FeatureFlags means all capabilities default to `false` (Python), which is safe but silently disables routing — better to crash loudly.

---

## 4. Python API — `FeatureFlagClient`

### 4.1 Design Decision: Direct File Read (Chosen)

**Decision:** The Python side reads `flags.json` directly from the filesystem.

**Justification:**
- **No bridge dependency:** Python can read flags even when the Elixir bridge is down (startup, crash, or Python-only mode).
- **Zero added latency:** No JSON-RPC round-trip for a flag check that is always < 1 KB local file I/O.
- **Consistency guarantee:** Elixir writes atomically to `flags.json` (`File.write/2` + fsync). Python reads are always consistent with the last persisted state.
- **Precedent:** `ConfigPath.home_dir()` already resolves `~/.code_puppy_ex/` paths.

**Rejected alternative — bridge RPC:** `elixir_bridge.call_method("feature_flags.enabled?", ...)` adds ~1ms RTT per flag check and creates a circular dependency (bridge needs flags, flags need bridge).

### 4.2 Proposed API

```python
class FeatureFlagClient:
    """Read-only client for ~/.code_puppy_ex/flags.json."""

    @staticmethod
    def enabled(capability: str) -> bool:
        """Check if a capability flag is enabled.

        Args:
            capability: One of 'llm_client', 'base_agent', 'tools',
                       'plugins', 'cli' (with or without 'elixir.' prefix).
        Returns:
            False if file missing, malformed, key absent, or parsing error.
        """

    @staticmethod
    def all() -> dict[str, bool]:
        """Return all capability flags as {key: bool}.

        Unknown keys in the file are excluded (not part of the capability
        enum). Missing keys default to False.
        """
```

### 4.3 File Path Resolution (Python Side)

```python
# Uses existing config_paths logic:
from code_puppy.config_paths import home_dir

flags_path = home_dir() / "flags.json"   # ~/.code_puppy_ex/flags.json or $PUP_EX_HOME/flags.json
```

### 4.4 Error Handling

| Scenario | Behavior |
|----------|----------|
| File not found | `enabled()` → `False`, `all()` → `{}` |
| File not valid JSON | Log warning, return defaults |
| Unknown key | Excluded from `all()` output |
| Non-boolean value | Treated as `False`, log warning |

---

## 5. CLI Integration

### 5.1 Decision: New `/feature-flags` Command (Chosen)

**Decision:** Add a new `/feature-flags` slash command. Keep existing `/flags` for WorkflowState only.

**Justification:**
- **Separation of concerns:** `/flags` manages workflow-state flags (e.g., `:did_execute_shell`, `:did_generate_code`). `/feature-flags` manages ADR-004 runtime routing flags. They are semantically distinct and should remain independently discoverable.
- **No breaking change:** Existing `/flags` users are unaffected.
- **Future aliasing remains reversible:** If consensus later favors unification, a `/flags` → `/feature-flags` alias can be added without breaking either command's API contract.

### 5.2 Command Spec (`/feature-flags`)

```
/feature-flags                    — list all feature flags with status
/feature-flags list               — list all feature flags
/feature-flags set <cap> <bool>   — set a capability (true/false)
/feature-flags reload             — reload flags from disk
```

**Implementation:** `CodePuppyControl.CLI.SlashCommands.Commands.FeatureFlags`

Display format (cyan-colored header, ✓/○ markers matching `/flags` style):

```
    Feature Flags

    ✓ elixir.llm_client      Route LLM client calls to Elixir
    ○ elixir.base_agent      Route agent execution to Elixir
    ○ elixir.tools           Route tool dispatch to Elixir
    ○ elixir.plugins         Load plugins via Elixir loader
    ○ elixir.cli             Route CLI/REPL to Elixir

    Use /feature-flags set <capability> <true|false> to change a flag
```

### 5.3 Registration

Registered in the SlashCommands registry at startup, same as other built-in commands (see `CodePuppyControl.CLI.SlashCommands.Registry.register_builtin_commands/0` in `application.ex`).

---

## 6. Application Supervision Integration

### 6.1 Placement

FeatureFlags must be started:
- **After** `Phoenix.PubSub` (for telemetry broadcast to subscribers)
- **After** `CodePuppyControl.Config.Writer` (for isolation guard + path resolution)
- **Before** any GenServer or consumer that calls `FeatureFlags.enabled?/1`

Canonical position in `application.ex` (commit `557e0690`):

```elixir
# Index ~20 in children list, after Config.Writer:
CodePuppyControl.Config.Writer,          # ~19
CodePuppyControl.FeatureFlags,           # ~20 — INSERT HERE
CodePuppyControl.RequestTracker,         # ~21
```

### 6.2 Startup Behavior

1. `init/1` reads `flags.json` from disk
2. If file missing → defaults to all-`false`
3. If file malformed → defaults to all-`false`, warning logged
4. Populates ETS cache (v1: GenServer state only; ETS migration deferred)
5. Emits `[:code_puppy_control, :feature_flags, :init]` telemetry

### 6.3 Shutdown

`FeatureFlags` is not graceful-shutdown sensitive in v1. It stops with the supervision tree. In-flight `enabled?/1` calls during shutdown return `false` via the `catch :exit` fallback.

---

## 7. Backward-Compatibility

During djs.4 rollout, three existing toggles remain functional. Their precedence rules:

### 7.1 Precedence Rule (highest to lowest)

1. **`flags.json` values** — Explicit per-capability toggles. These are the canonical source during Phase H. When `flags.json` exists and a key is present, its value wins.
2. **`PUP_RUNTIME=elixir`** — Legacy binary enabler. When set to `"elixir"`, it acts as if ALL five capabilities are `true` (override). However, if `flags.json` explicitly has a flag set to `false`, that per-capability `false` **wins** over the env var.
3. **`enable_elixir_message_shadow_mode`** — Application config toggle for shadow-mode only. Unchanged by djs.4. This continues to control only the message-shadowing feature, independent of capability flags.
4. **`is_pup_ex()`** — Python-side binary detection (`PUP_EX_HOME` or `PUP_RUNTIME=elixir`). Unchanged. Used by Python to decide home directory routing. During Phase H, Python's `is_pup_ex()` continues to work as before — djs.4 does not change the detection logic.

### 7.2 Interaction Matrix

| `flags.json` | `PUP_RUNTIME` | Effective State | Rationale |
|---|---|---|---|
| `llm_client: true` | unset | `llm_client: true` | flags.json explicit win |
| `llm_client: false` | `elixir` | `llm_client: false` | flags.json explicit win over env |
| missing file | `elixir` | ALL five: `true` | Env var provides global override |
| missing file | unset | ALL five: `false` | Default safe mode (Python) |
| `tools: true`, others absent | unset | `tools: true`, others `false` | Per-key granularity works |

### 7.3 No Breaking Changes

- Existing `.bashrc`/`.zshrc` `PUP_RUNTIME=elixir` exports continue to work.
- Existing `is_pup_ex()` callers in Python continue to work.
- Existing `enable_elixir_message_shadow_mode` config continues to work independently.
- No existing CLI flags are removed or renamed.

---

## 8. Test Plan

### 8.1 Unit Tests

| Test Area | Test File | Coverage |
|---|---|---|
| GenServer state | `feature_flags_test.exs` | Start/stop, init from disk, default state |
| `enabled?/1` | `feature_flags_test.exs` | Known cap → correct bool, unknown cap → raises, GenServer down → false |
| `set/2` | `feature_flags_test.exs` | Set true/false, persist to disk, round-trip consistency |
| `set/2` error | `feature_flags_test.exs` | Unknown cap, invalid value, disk failure |
| `list/0` | `feature_flags_test.exs` | Returns all 5 caps, correct status |
| `reset/0` | `feature_flags_test.exs` | All false, persisted to disk |
| `reload/0` | `feature_flags_test.exs` | File changed on disk → picks up changes |
| Capability definitions | `flags_test.exs` | All caps known, resolve/1, json_key/1 |
| Malformed JSON | `feature_flags_test.exs` | Empty file, non-JSON, non-object → defaults |
| Unknown JSON keys | `feature_flags_test.exs` | Silently ignored |
| Non-boolean values | `feature_flags_test.exs` | Warning logged, default used |
| Isolation guard | `isolation_test.exs` | Write outside home → isolation violation |
| Concurrent writers | `feature_flags_test.exs` | Same-key concurrent sets → last-writer-wins |

### 8.2 Property Tests (StreamData)

| Property | File | Description |
|---|---|---|
| Unknown-caps rejected | `feature_flags_test.exs` | For any atom not in `Flags.names()`, `resolve/1` returns `{:error, :unknown}` |
| Round-trip consistency | `feature_flags_test.exs` | For any valid flag assignment, `enabled?/1` returns the set value |
| Degraded broadcast | `feature_flags_test.exs` | When GenServer is stopped, `enabled?/1` returns `false` (safe default) |

### 8.3 Mock Strategy

Per project's "Test-Drift Prevention" rules (mock at boundary, not internals):

- **Filesystem:** The GenServer's `load_from_disk/0` and `persist_to_disk/1` use `File.read/1` and `File.write/2`. Tests manipulate the actual `flags.json` file on disk (temp dir) rather than mocking `File` — this catches real I/O error paths.
- **Isolation guard:** `Isolation.check_allowed/2` is tested via `isolation_test.exs` which verifies the guard raises on out-of-home writes.
- **Telemetry:** Attach to `:code_puppy_control` telemetry events and assert emission counts/metadata.

### 8.4 Integration Tests (for file watcher / hot-reload)

- Manual file edit → `FeatureFlags.reload()` → verify `enabled?/1` reflects new values.
- Future: automated file-watcher test using `FileSystem` (post-v1).

---

## 9. Acceptance Criteria

**djs.4 is "done" when all of the following are true:**

- [ ] 9.1 `CodePuppyControl.FeatureFlags` starts in the supervision tree without crashing.
- [ ] 9.2 `FeatureFlags.enabled?/1` returns correct values for all 5 capabilities.
- [ ] 9.3 `FeatureFlags.enabled?(:unknown)` raises `ArgumentError`.
- [ ] 9.4 `FeatureFlags.enabled?/1` returns `false` when GenServer is unavailable.
- [ ] 9.5 `FeatureFlags.set/2` persists changes to `~/.code_puppy_ex/flags.json`.
- [ ] 9.6 `FeatureFlags.set/2` with out-of-home path raises isolation violation.
- [ ] 9.7 `FeatureFlags.reload/0` picks up manual file edits.
- [ ] 9.8 `FeatureFlags.list/0` returns all 5 capabilities with status.
- [ ] 9.9 Python `FeatureFlagClient.enabled()` reads the same file correctly.
- [ ] 9.10 Python `FeatureFlagClient.enabled()` returns `False` for missing/malformed file.
- [ ] 9.11 `/feature-flags` slash command lists flags, accepts `set` and `reload`.
- [ ] 9.12 `/feature-flags` does not affect existing `/flags` (WorkflowState) behavior.
- [ ] 9.13 `PUP_RUNTIME=elixir` continues to work as a global override when `flags.json` is absent.
- [ ] 9.14 `enable_elixir_message_shadow_mode` config toggle continues to work independently.
- [ ] 9.15 `is_pup_ex()` Python detection continues to work unchanged.
- [ ] 9.16 All unit, property, and acceptance tests pass with `mix test --warnings-as-errors`.
- [ ] 9.17 `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass.
- [ ] 9.18 All touched files are ≤ 600 lines (project hard cap).

---

## 10. Hand-off to Downstream Dependents

### 10.1 Contract for `code_puppy-bwt` (Runtime Selector)

The runtime selector (`bwt`) **must**:

1. **Call `FeatureFlags.enabled?/1` at routing decision points.** For each incoming request, determine the capability type (e.g., LLM chat → `:llm_client`), then check `FeatureFlags.enabled?(:llm_client)`.
2. **Not cache flag results beyond a single request.** Flags can change between requests via `set/2` or `reload/0`.
3. **Respect the catch-`:exit` fallback.** If the GenServer is down, `enabled?/1` returns `false` — route to Python.
4. **Not short-circuit on unknown capabilities.** If bwt encounters a capability atom that `FeatureFlags` raises on, that's a development-time error (should be caught in CI).
5. **Use the capability enum from `FeatureFlags.Flags`** (or define its own matching enum) — do not hardcode string literals.

**Contract API:**

```elixir
# bwt calls this at every routing decision
case CodePuppyControl.FeatureFlags.enabled?(capability) do
  true  -> route_to_elixir(request)
  false -> route_to_python(request)
end
```

### 10.2 Contract for `code_puppy-djs.6` (Rollout Controller)

The rollout controller (`djs.6`) **must**:

1. **Write to `flags.json`** via `FeatureFlags.set/2` (or directly, but prefer the API for consistency).
2. **Read current state** via `FeatureFlags.list/0` or `FeatureFlags.enabled?/1`.
3. **Not mutate `flags.json` while concurrent reads are in-flight** — `set/2` is synchronous (GenServer.call), so writes are serialized.
4. **Use telemetry** `[:code_puppy_control, :feature_flags, ...]` for observability of flag changes.
5. **Respect the binary flag model** — djs.6 adds percentage enablement *on top of* the binary flag. E.g., "50% of `llm_client` requests" means `enabled?(:llm_client)` returns `true` for 50% of calls. How djs.6 implements this (probabilistic sampling, etc.) is its own design.

---

## Appendix A: Implementation Status

| Component | Status | Branch | Commit |
|---|---|---|---|
| Elixir GenServer + Flags module | ✅ Done (round 1) | `feature/code-puppy-djs-4-feature-flags` | `557e0690` |
| Supervision tree placement | ✅ Done (round 1) | Same | Same |
| `paths.ex` flags_file/0 | ✅ Done (round 1) | Same | Same |
| Test suite (35 tests + 1 property) | ✅ Done (round 1) | Same | Same |
| Polish sweep (6 P2/P3 nits) | ✅ Done (round 1) | Same | `906d1333` |
| Python FeatureFlagClient | ⚠️ Done (round 2.A) | `feature/code-puppy-djs-4-6-python-mirror` | TBD |
| `/feature-flags` slash command | ⚠️ Done (round 2.B) | `feature/code-puppy-djs-4-7-feature-flags-command` | TBD |
| First consumer integration (LLM) | ⚠️ Parked (round 2.C) | Stash `7b23ce24664e` | Parked |
| ETS direct-read migration | ❌ Deferred | — | Future |
| File-watcher for hot-reload | ❌ Deferred | — | Future |
| Version field in schema | ❌ Deferred | — | Future |

**Landing coordination:** `feature/code-puppy-djs-4-family-land` is the staging branch for round 1 + round 2 integration.

## Appendix B: File Inventory

```
# New files (round 1)
elixir/code_puppy_control/lib/code_puppy_control/feature_flags.ex
elixir/code_puppy_control/lib/code_puppy_control/feature_flags/flags.ex
elixir/code_puppy_control/test/code_puppy_control/feature_flags_test.exs
elixir/code_puppy_control/test/code_puppy_control/feature_flags/flags_test.exs
elixir/code_puppy_control/test/code_puppy_control/feature_flags/isolation_test.exs

# Modified files (round 1)
elixir/code_puppy_control/lib/code_puppy_control/application.ex    — added FeatureFlags to children
elixir/code_puppy_control/lib/code_puppy_control/config/paths.ex   — added flags_file/0
elixir/code_puppy_control/config/test.exs                           — test config

# New files (round 2 — on respective branches)
code_puppy/plugins/feature_flag_client/register_callbacks.py        — Python mirror (round 2.A)
elixir/code_puppy_control/lib/code_puppy_control/cli/slash_commands/commands/feature_flags.ex  — CLI (round 2.B)
```

## Appendix C: Key Commit Messages

| Commit | Message |
|---|---|
| `557e0690` | `feat(feature-flags): ADR-004 Phase H feature flags foundation (code_puppy-djs.4)` |
| `3c05dcac` | `fix(feature-flags): Isolation guard integration + reset safety (code_puppy-djs.4)` |
| `4e2438b3` | `chore: remove tracker churn and fix unused variable` |
| `906d1333` | `refactor: split feature_flags_test.exs under 600-line cap` |
