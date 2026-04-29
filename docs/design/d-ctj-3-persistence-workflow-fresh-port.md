# d-ctj-3: Persistence + WorkflowState Port — Design

**Author:** elixir-programmer-1c405b  
**Date:** 2025-07-11  
**Base:** `fix/security-regression-and-test-triage` post d-ctj-1 merge (HEAD `ec1a9b54`)  
**Abandoned branch:** `feature/d-ctj-3-persistence-workflow` @ `3341a7eb`  

---

## 1. Python Contract Summary

### 1.1 persistence.py

**Location:** `code_puppy/persistence.py` (311 lines)

**Purpose:** Pure utility module providing **atomic file I/O** — no DB, no session management, no state management. Every write uses temp-file + atomic replace to prevent partial/corrupt files on crash.

**Public API:**

| Function | Purpose |
|----------|---------|
| `safe_resolve_path(path, allowed_parent=None)` | Normalize path, optionally enforce parent containment |
| `atomic_write_text(path, content, encoding="utf-8")` | Atomic text write |
| `atomic_write_bytes(path, data)` | Atomic binary write |
| `atomic_write_json(path, data, indent=2, default=None)` | Atomic JSON write (pretty) |
| `atomic_write_msgpack(path, data, default=None)` | Atomic compact JSON write (historical name, now JSON) |
| `read_json(path, default=None)` | Safe JSON read |
| `read_msgpack(path, default=None)` | Safe compact JSON read (historical name) |
| `atomic_write_text_async(...)` | Async wrapper via `asyncio.to_thread` |
| `atomic_write_bytes_async(...)` | Async wrapper |
| `atomic_write_msgpack_async(...)` | Async wrapper |
| `read_json_async(...)` | Async wrapper |
| `read_msgpack_async(...)` | Async wrapper |

**Key invariants:**
- `_check_isolation_guard`: ADR-003 belt-and-suspenders check for config-home writes
- Path traversal prevention via `os.path.normpath` (no symlink following)
- Thread-safe directory creation cache (`_created_dirs` + lock)
- Cleanup of temp files on write failure

**What persistence.py is NOT:**
- Not a database layer
- Not session storage
- Not workflow state management
- Not a config key-value store
- Just **safe file I/O**

### 1.2 workflow_state.py

**Location:** `code_puppy/workflow_state.py` (268 lines)

**Purpose:** Per-run **ephemeral** workflow flag tracking. Uses `ContextVar` for async-safe per-context state. **Not persisted to disk** in Python.

**Public API:**

| Function | Purpose |
|----------|---------|
| `get_workflow_state()` | Get/create current context's WorkflowState |
| `reset_workflow_state()` | Reset and return fresh state |
| `set_flag(flag, value=True)` | Set a workflow flag (enum or string) |
| `clear_flag(flag)` | Clear a flag |
| `has_flag(flag)` | Check if flag is active |
| `set_metadata(key, value)` | Store metadata |
| `get_metadata(key, default=None)` | Read metadata |
| `increment_counter(key, amount=1)` | Increment a counter in metadata |
| `register_callback_handlers()` | Wire auto-flag-setting into callback system |
| `unregister_callback_handlers()` | Remove callback wiring |
| `detect_and_mark_plan_from_response(text, min_tasks=2)` | Heuristic plan detection |

**15 flags:** `DID_GENERATE_CODE`, `DID_EXECUTE_SHELL`, `DID_LOAD_CONTEXT`, `DID_CREATE_PLAN`, `DID_ENCOUNTER_ERROR`, `NEEDS_USER_CONFIRMATION`, `DID_SAVE_SESSION`, `DID_USE_FALLBACK_MODEL`, `DID_TRIGGER_COMPACTION`, `DID_MAKE_API_CALL`, `DID_EDIT_FILE`, `DID_CREATE_FILE`, `DID_DELETE_FILE`, `DID_RUN_TESTS`, `DID_CHECK_LINT`

**Key architectural note:** Python `workflow_state.py` is **purely ephemeral** — state lives in a `ContextVar`, dies with the context, and is never persisted. The abandoned Elixir branch added persistence (`save`/`load`) that Python doesn't have.

---

## 2. Current Elixir Inventory (post d-ctj-1 merge)

### 2.1 `persistence.ex` (406 lines) — **ALREADY FULLY PORTED**

The current `persistence.ex` is a **complete, production-quality port** of `persistence.py`:

| Python | Elixir | Status |
|--------|--------|--------|
| `safe_resolve_path` | `Persistence.safe_resolve_path/1,2` | ✅ Done (returns `{:ok, path}` / `{:error, reason}`) |
| `_check_isolation_guard` | `Persistence.check_isolation_guard/1` | ✅ Done (returns `:ok` / `{:error, :isolation_violation, msg}`) |
| `atomic_write_text` | `Persistence.atomic_write_text/2` | ✅ Done |
| `atomic_write_bytes` | `Persistence.atomic_write_bytes/2` | ✅ Done |
| `atomic_write_json` | `Persistence.atomic_write_json/2,3` | ✅ Done |
| `atomic_write_msgpack` | `Persistence.atomic_write_compact_json/2,3` | ✅ Done (renamed, Python compat name preserved) |
| `read_json` | `Persistence.read_json/1,2` | ✅ Done |
| `read_msgpack` | `Persistence.read_compact_json/1,2` | ✅ Done (renamed) |
| async wrappers | Not ported (unnecessary on BEAM) | ✅ Intentional omission, documented |
| directory cache | Not ported (File.mkdir_p is cheap) | ✅ Intentional omission, documented |
| Uses `SafeWrite` | Delegates to `Tools.FileModifications.SafeWrite` | ✅ More idiomatic than raw temp-file |

**Improvements over Python:**
- All functions return tagged tuples instead of raising/returning-raw
- Integration with existing `SafeWrite` module instead of duplicating atomic-write logic
- Proper `@spec` on all public functions
- No threading primitives needed (BEAM)

### 2.2 `workflow_state.ex` (facade, ~180 lines) — **ALREADY FULLY PORTED**

The current `WorkflowState` module is a **backward-compatible facade** delegating all calls to `Workflow.State`:

| WorkflowState (facade) | Delegates to | Status |
|------------------------|-------------|--------|
| `set_flag/1` | `Workflow.State.set_flag/1` | ✅ |
| `has_flag?/1` | `Workflow.State.has_flag?/1` | ✅ |
| `clear_flag/1` | `Workflow.State.clear_flag/1` | ✅ |
| `reset/0` | `Workflow.State.reset/0` | ✅ |
| `put_metadata/2` | `Workflow.State.put_metadata/2` | ✅ |
| `get_metadata/2` | `Workflow.State.get_metadata/2` | ✅ |
| `new/0` | Creates `%WorkflowState{}` facade struct | ✅ |
| `all_flags/0` | `Workflow.State.Flags.all_flags/0` | ✅ |
| `get_run_key/0` | `Workflow.State.RunKey.get_run_key/0` | ✅ |
| `set_run_key/1` | `Workflow.State.RunKey.set_run_key/1` | ✅ |
| `clear_run_key/0` | `Workflow.State.RunKey.clear_run_key/0` | ✅ |

### 2.3 `Workflow.State` (facade + submodules, ~350 lines total) — **ALREADY FULLY PORTED**

| Submodule | Lines | Status |
|-----------|-------|--------|
| `Workflow.State` (facade) | ~210 | ✅ Full API including `resolve_flag/1`, `increment_counter/2` |
| `Workflow.State.Flags` | ~80 | ✅ All 15 flags, `resolve_flag/1` |
| `Workflow.State.Store` | ~220 | ✅ Agent-backed, per-run-key isolation |
| `Workflow.State.RunKey` | ~120 | ✅ Process dict + explicit derivation + session index |
| `Workflow.State.CallbackHandlers` | ~160 | ✅ All 5 callback handlers, async-safe run_key derivation |
| `Workflow.State.PlanDetection` | ~50 | ✅ Heuristic numbered/bullet list detection |

### 2.4 `SessionStorage.Store` (d-ctj-1, ~320 lines) — **NEWLY MERGED**

| Feature | Status |
|---------|--------|
| SQLite + ETS + PubSub write-through | ✅ |
| `save_session/2,3`, `load_session/1`, `delete_session/1` | ✅ |
| `update_session/2`, `search_sessions/1` | ✅ |
| Terminal session tracking + crash recovery | ✅ |
| ETS-backed read cache (O(1) hot path) | ✅ |

### 2.5 Existing Ecto schemas

| Schema | Table | Status |
|--------|-------|--------|
| `Sessions.ChatSession` | `chat_sessions` | ✅ Already migrated |
| `Workflow.Step` | `workflow_steps` | ✅ Already migrated |

### 2.6 What does NOT exist on current base

| Module | Status |
|--------|--------|
| `Persistence.PersistedConfig` schema | ❌ Does not exist |
| `Persistence.WorkflowSnapshot` schema | ❌ Does not exist |
| `Persistence.Store` (Ecto CRUD) | ❌ Does not exist |
| `workflow_snapshots` table | ❌ No migration |
| `persisted_configs` table | ❌ No migration |
| `WorkflowState.save/1` / `WorkflowState.load/1` | ❌ No persistence hooks |

---

## 3. Test Contracts from Abandoned Branch

### 3.1 `persistence/store_test.exs` (333 lines, ~21 tests)

Tests an **Ecto CRUD store** with 3 entity types: `:config`, `:workflow_snapshot`, `:session`.

**Config CRUD (8 tests):**
- `create :config` — creates with key and value
- `create :config` — returns changeset error for missing key
- `get :config` — retrieves by key
- `get_config/2` — retrieves by namespace + key
- `get_config/2` — returns `:not_found` for wrong namespace
- `update :config` — updates existing config
- `update :config` — returns `:not_found` for missing
- `delete :config` — deletes and confirms gone
- `list :config` — lists all, filters by namespace, respects limit
- `put_config/2` — creates on first call (upsert)
- `put_config/3` — updates on second call, supports namespace

**Workflow Snapshot CRUD (6 tests):**
- `create :workflow_snapshot` — creates with flags and metadata
- `create :workflow_snapshot` — returns error for missing session_id
- `get :workflow_snapshot` — retrieves latest by session_id
- `get :workflow_snapshot` — returns `:not_found`
- `update :workflow_snapshot` — updates flags
- `delete :workflow_snapshot` — deletes
- `list :workflow_snapshot` — lists all, filters by session_id

**Session CRUD (4 tests):**
- `create :session` — creates chat session
- `get :session` — retrieves existing
- `list :session` — lists sessions
- `delete :session` — deletes

**Roundtrip tests (2 tests):**
- Config full lifecycle (create → get → update → delete)
- Workflow snapshot full lifecycle

### 3.2 `workflow_state_test.exs` (286 lines, ~28 tests)

**Flag definitions (3 tests):**
- `all_flags/0` — non-empty, well-formed
- `flag_names/0` — matches all_flags keys
- All 15 Python flags present

**Known flag checks (3 tests):**
- `known_flag?/1` — true for known, false for unknown, false for non-atoms

**Flag set/clear/has (5 tests):**
- `set_flag` + `has_flag?` roundtrip
- Multiple flags work
- Unknown flag is no-op
- `has_flag?` returns false for unknown
- String flag support (new via Workflow.State)

**Clear flag (3 tests):**
- Clears previously set
- Unknown flag is no-op
- Unset flag is no-op

**Reset (2 tests):**
- Clears all flags and metadata
- Returns fresh state

**Metadata (4 tests):**
- put/get roundtrip
- Default for missing keys
- Full map retrieval
- Overwrites existing key

**Active count (3 tests):**
- Starts at zero
- Increments on set
- Decrements on clear

**Summary (3 tests):**
- Placeholder when no flags
- Lists active flags
- Sorts alphabetically

**to_map (1 test):**
- Serializes to map

**Persistence: save/load (4 tests — THE NEW STUFF):**
- Roundtrips state through SQLite (save → reset → load → verify)
- save/1 updates existing snapshot (upsert)
- load/1 returns :not_found for missing session
- delete_snapshot/1 removes saved snapshot

---

## 4. Gap Analysis

### 4.1 Venn Diagram: Python persistence.py vs Elixir Store vs Gap

| Concern | Python `persistence.py` | Elixir `Persistence.ex` (current) | Elixir `SessionStorage.Store` (d-ctj-1) | Gap |
|---------|------------------------|-----------------------------------|----------------------------------------|-----|
| Atomic file write (text) | ✅ | ✅ | — | None |
| Atomic file write (bytes) | ✅ | ✅ | — | None |
| Atomic JSON write/read | ✅ | ✅ | — | None |
| Path safety / traversal | ✅ | ✅ | — | None |
| ADR-003 isolation guard | ✅ | ✅ | — | None |
| Async wrappers | ✅ | ❌ (intentional) | — | None (Task.async is the Elixir way) |
| Session data persistence | ❌ | ❌ | ✅ | None (Store covers this) |
| Config key-value persistence | ❌ | ❌ | ❌ | **GAP**: No `PersistedConfig` schema |
| Workflow snapshot persistence | ❌ | ❌ | ❌ | **GAP**: No `WorkflowSnapshot` schema |
| Ecto CRUD store | ❌ | ❌ | ❌ | **GAP**: No `Persistence.Store` |
| File backup/restore | ❌ | ❌ | ❌ | Minor (branch added `backup/restore`) |

**Key insight:** Python `persistence.py` is **purely about file I/O**. It has NO database layer, NO config store, NO workflow snapshot persistence. The abandoned branch **invented** these Ecto-backed features that Python doesn't have. These are **new Elixir-only features** justified by §4.1 ("domain truth is persistent").

### 4.2 Venn Diagram: Python workflow_state.py vs Current Elixir WorkflowState

| Concern | Python `workflow_state.py` | Current Elixir `Workflow.State` | Abandoned Branch's Addition | Gap |
|---------|--------------------------|-------------------------------|----------------------------|-----|
| 15 flags defined | ✅ | ✅ | Same | None |
| set/clear/has flag | ✅ | ✅ | Same | None |
| Metadata put/get | ✅ | ✅ | Same | None |
| Counter increment | ✅ | ✅ | Same | None |
| ContextVar / process dict | ✅ (ContextVar) | ✅ (process dict) | Same | None |
| Callback handlers (5) | ✅ | ✅ | Same | None |
| Plan detection | ✅ | ✅ | Same | None |
| Per-run isolation | ❌ (single context) | ✅ (run keys) | Same | None (Elixir is ahead) |
| Async-safe run key derivation | N/A | ✅ | Same | None |
| **save(session_id)** | ❌ | ❌ | ✅ NEW | **GAP** |
| **load(session_id)** | ❌ | ❌ | ✅ NEW | **GAP** |
| **delete_snapshot(session_id)** | ❌ | ❌ | ✅ NEW | **GAP** |

**Key insight:** The ONLY gap between current Elixir and the abandoned branch is **persistence of workflow state** (save/load/delete_snapshot) and the supporting infrastructure (`Persistence.Store`, `PersistedConfig`, `WorkflowSnapshot` schemas, `workflow_snapshots` migration).

### 4.3 What the abandoned branch added that Python doesn't have

These are **Elixir-only additions** justified by §4.1:

1. **`Persistence.PersistedConfig`** — Generic namespaced key-value config storage in SQLite
2. **`Persistence.WorkflowSnapshot`** — Point-in-time workflow state snapshots in SQLite
3. **`Persistence.Store`** — Unified Ecto CRUD facade for configs, snapshots, and sessions
4. **`workflow_snapshots` migration** — SQLite table for snapshots
5. **`WorkflowState.save/1`** — Serialize current Agent state to SQLite
6. **`WorkflowState.load/1`** — Hydrate Agent state from SQLite
7. **`WorkflowState.delete_snapshot/1`** — Remove saved snapshot

### 4.4 Redundancy with SessionStorage.Store

| Feature | Abandoned `Persistence.Store` | Current `SessionStorage.Store` | Verdict |
|---------|-------------------------------|-------------------------------|---------|
| Session CRUD | ✅ (`:session` type) | ✅ (primary purpose) | **REDUNDANT** — Store already handles sessions |
| Ecto-backed | ✅ | ✅ (via `Sessions` module) | Same |
| ETS cache | ❌ | ✅ | Store is superior |
| PubSub events | ❌ | ✅ | Store is superior |
| Terminal recovery | ❌ | ✅ | Store is superior |
| Search/filter | ❌ | ✅ | Store is superior |

**The abandoned branch's session CRUD in `Persistence.Store` duplicates `SessionStorage.Store` and should be dropped.** This is a clear case of the branch designing against a pre-d-ctj-1 world where session storage was less mature.

---

## 5. Recommendation: Fresh Port (Drastically Reduced Scope)

### Why NOT rebase:

1. **Add/add conflict on `persistence.ex`**: Both base and branch rewrote the file from scratch. Base version (406 lines) is more complete and idiomatic (returns tagged tuples, uses `SafeWrite`, has `@spec`). Branch version (315 lines) is simpler but less robust. A rebase would lose the base's improvements.

2. **Session CRUD redundancy**: The branch's `Persistence.Store` includes `:session` CRUD that is now fully covered by `SessionStorage.Store` (d-ctj-1). Rebasing this would create architectural duplication.

3. **WorkflowState architecture drift**: The base has evolved `WorkflowState` into a facade over `Workflow.State` with submodules (Flags, Store, RunKey, CallbackHandlers, PlanDetection). The branch's `WorkflowState` is still a monolithic Agent. Merging would lose the base's cleaner architecture.

4. **Migration conflict**: The branch creates `20250419000001_create_workflow_steps.exs` which already exists on the base (same content, different provenance). The branch also creates `20250420000002_create_workflow_snapshots.exs` which is new and needed.

### Why NOT full descope:

The persistence of workflow state to SQLite (save/load) IS justified by §4.1. The current Agent-only state is **crash-volatile** — if the Agent process dies, all workflow flags are lost. For session resumption and crash recovery, we need snapshots.

### Recommended: Fresh port of the **gap only**

Port the three things the base is missing:
1. `Persistence.PersistedConfig` schema + migration
2. `Persistence.WorkflowSnapshot` schema + migration  
3. `Persistence.Store` (Ecto CRUD, **without** `:session` type — that's `SessionStorage.Store`)
4. `WorkflowState.save/1`, `WorkflowState.load/1`, `WorkflowState.delete_snapshot/1`

---

## 6. Proposed Design

### 6.1 Module layout

```
lib/code_puppy_control/
  persistence.ex                          # EXISTING — no changes needed
  persistence/
    persisted_config.ex                    # NEW — Ecto schema (~60 lines)
    workflow_snapshot.ex                   # NEW — Ecto schema (~70 lines)
    store.ex                               # NEW — Ecto CRUD for :config and :workflow_snapshot (~180 lines)
  workflow_state.ex                        # MODIFY — add save/1, load/1, delete_snapshot/1
  workflow/
    state.ex                               # MODIFY — add persistence delegates
    state/
      store.ex                             # MODIFY — add save/1, load/1, delete_snapshot/1

priv/repo/migrations/
  20250420000002_create_workflow_snapshots.exs  # NEW — workflow_snapshots table
  20250421000001_create_persisted_configs.exs   # NEW — persisted_configs table
```

**Line budget:**
| Module | Est. Lines | Under 600? |
|--------|-----------|------------|
| `Persistence.PersistedConfig` | ~60 | ✅ |
| `Persistence.WorkflowSnapshot` | ~70 | ✅ |
| `Persistence.Store` | ~180 | ✅ |
| Changes to `workflow_state.ex` | +20 | ✅ (total ~200) |
| Changes to `Workflow.State` | +10 | ✅ (total ~220) |
| Changes to `Workflow.State.Store` | +40 | ✅ (total ~260) |

### 6.2 Persistence vs Store boundary

```
                     ┌──────────────────────┐
                     │   Persistence.ex     │  ← Atomic file I/O (EXISTING)
                     │   (pure functions)   │  ← No Ecto, no DB
                     └──────────────────────┘

                     ┌──────────────────────┐
                     │  Persistence.Store   │  ← Ecto CRUD (NEW)
                     │  :config             │  ← PersistedConfig schema
                     │  :workflow_snapshot   │  ← WorkflowSnapshot schema
                     └──────────────────────┘

                     ┌──────────────────────┐
                     │ SessionStorage.Store  │  ← Session CRUD (EXISTING, d-ctj-1)
                     │  GenServer + ETS      │  ← NOT duplicated in Persistence.Store
                     └──────────────────────┘

                     ┌──────────────────────┐
                     │  WorkflowState       │  ← Ephemeral flags (EXISTING)
                     │  Agent + run keys    │  ← save/load delegate to Persistence.Store
                     └──────────────────────┘
```

**Call graph:**
- `WorkflowState.save(session_id)` → `Workflow.State.Store.save/1` → `Persistence.Store.create/update(:workflow_snapshot, ...)` → `Repo.insert/update`
- `WorkflowState.load(session_id)` → `Workflow.State.Store.load/1` → `Persistence.Store.get(:workflow_snapshot, session_id)` → then Agent.update
- Config persistence: `Persistence.Store.put_config/2,3` → direct Repo calls

**Session CRUD is ONLY in `SessionStorage.Store`** — no duplication.

### 6.3 Migration strategy

Two new migrations needed:

**Migration 1: `20250420000002_create_workflow_snapshots.exs`**
- Table: `workflow_snapshots`
- Columns: `id`, `session_id` (TEXT, indexed), `flags` (JSON array stored as TEXT), `metadata` (JSON map stored as TEXT), `start_time` (INTEGER), timestamps
- Indexes: `session_id`, `inserted_at`
- Ported directly from abandoned branch (same schema, same migration — verified identical)

**Migration 2: `20250421000001_create_persisted_configs.exs`**
- Table: `persisted_configs`
- Columns: `id`, `key` (TEXT), `namespace` (TEXT, default "default"), `value` (JSON map), timestamps
- Indexes: unique on `(namespace, key)`

**Important:** The `workflow_steps` migration already exists on base (identical to branch's), so no conflict there.

**Note on flags storage:** The abandoned branch uses `{:array, :string}` for flags in Ecto. With SQLite3, this serializes as a JSON array in a TEXT column. This works correctly with `ecto_sqlite3` and is the idiomatic approach. Same for `:map` fields (JSON objects in TEXT columns).

### 6.4 Public API (per module)

#### `Persistence.PersistedConfig` (schema)
```elixir
@spec changeset(t(), map()) :: Ecto.Changeset.t()
@spec to_map(t()) :: map()
# Fields: id, key, namespace (default "default"), value (map), timestamps
# Unique constraint on {namespace, key}
```

#### `Persistence.WorkflowSnapshot` (schema)
```elixir
@spec changeset(t(), map()) :: Ecto.Changeset.t()
@spec to_map(t()) :: map()
# Fields: id, session_id, flags (array of strings), metadata (map), start_time (integer), timestamps
# Index on session_id, inserted_at
```

#### `Persistence.Store` (CRUD)
```elixir
# Entity types: :config | :workflow_snapshot (NO :session — that's SessionStorage.Store)
@spec create(entity_type(), map()) :: {:ok, entity()} | {:error, Ecto.Changeset.t()}
@spec get(entity_type(), key()) :: {:ok, entity()} | {:error, :not_found}
@spec update(entity_type(), key(), map()) :: {:ok, entity()} | {:error, :not_found | Ecto.Changeset.t()}
@spec delete(entity_type(), key()) :: :ok | {:error, :not_found}
@spec list(entity_type(), keyword()) :: [entity()]
@spec put_config(String.t(), map()) :: {:ok, PersistedConfig.t()} | {:error, Ecto.Changeset.t()}
@spec put_config(String.t(), String.t(), map()) :: {:ok, PersistedConfig.t()} | {:error, Ecto.Changeset.t()}
@spec get_config(String.t(), String.t()) :: {:ok, PersistedConfig.t()} | {:error, :not_found}
```

#### `WorkflowState` (additions)
```elixir
@spec save(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
@spec load(String.t()) :: {:ok, t()} | {:error, :not_found}
@spec delete_snapshot(String.t()) :: :ok | {:error, :not_found}
```

#### `Workflow.State` (additions — delegates to Store)
```elixir
@spec save(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
@spec load(String.t()) :: {:ok, State.t()} | {:error, :not_found}
@spec delete_snapshot(String.t()) :: :ok | {:error, :not_found}
```

---

## 7. Test Plan

### 7.1 Ported from abandoned branch (with modifications)

**`persistence/store_test.exs`** — Port ~21 tests, but:
- **DROP** all `:session` CRUD tests (4 tests) — covered by SessionStorage.Store tests
- **DROP** `create :session` and `list :session` tests
- **KEEP** all `:config` CRUD tests (~8 tests)
- **KEEP** all `:workflow_snapshot` CRUD tests (~6 tests)
- **KEEP** roundtrip tests for config and snapshot (2 tests)
- Estimated: ~17 tests

**`workflow_state_test.exs`** — Port 4 persistence tests:
- Roundtrip state through SQLite (save → reset → load → verify)
- save/1 updates existing snapshot
- load/1 returns :not_found for missing session
- delete_snapshot/1 removes saved snapshot
- **MODIFY**: Use `Workflow.State` directly (not facade) since persistence is new API
- **MODIFY**: Add Ecto sandbox setup (branch had this, current base doesn't for this file)

### 7.2 New tests needed

- `Persistence.Store.put_config/2,3` upsert behavior (ported from branch)
- `Persistence.Store` with namespace-scoped operations (ported from branch)
- `WorkflowState.save/1` + `WorkflowState.load/1` through facade (thin integration test)
- Edge case: load after Agent crash/restart (verify Agent re-hydrates from snapshot)
- Edge case: save with run_key (verify correct per-run state is snapshotted)

### 7.3 Existing tests that need modification

| Test file | Change | Reason |
|-----------|--------|--------|
| `workflow_state_test.exs` | Add Ecto sandbox checkout + persistence tests | New save/load API |
| `persistence_test.exs` | No change needed | `persistence.ex` is unchanged |

### 7.4 Test count estimate

| Category | Tests |
|----------|-------|
| Persistence.Store config CRUD | ~8 |
| Persistence.Store workflow snapshot CRUD | ~6 |
| Persistence.Store roundtrips | 2 |
| WorkflowState persistence (save/load/delete) | 4 |
| WorkflowState persistence edge cases | 2-3 |
| **Total new tests** | **~22** |

---

## 8. Risks and Open Questions

### 8.1 Open questions (need architect/user input)

1. **Is `PersistedConfig` actually used by anything?** The abandoned branch created it but I see no callers on either the branch or the base. Config persistence in Python happens via file I/O (`persistence.py`), not a DB. The only justification for `PersistedConfig` would be if some future feature needs namespaced key-value storage in SQLite. **Recommendation:** Port it anyway (it's small and tested), but flag it as potentially dead code. If the architect confirms no caller, we could defer it.

2. **Should `WorkflowState.save/1` use `Ecto.Multi` for dual-write (§6.3)?** The abandoned branch's `save/1` does a simple get-then-update pattern without `Multi`. Since `save/1` only writes a `WorkflowSnapshot` row (no event row), the dual-write rule doesn't strictly apply. But if we want to emit a telemetry event alongside the snapshot write, we should use `Multi`. **Recommendation:** Use simple Repo.upsert for now (no event row), add a `:telemetry.execute` call after the transaction for observability.

3. **Should `Persistence.Store` be a GenServer or pure context module?** The abandoned branch made it a pure context module (just functions calling `Repo`). This is more idiomatic — `SessionStorage.Store` is a GenServer because it manages ETS tables, but `Persistence.Store` doesn't need that. **Recommendation:** Pure context module (same as abandoned branch).

4. **Migration timestamp collision:** The base has `20250419000001_create_workflow_steps.exs`. The branch's `workflow_snapshots` migration is `20250420000002`. We should keep the same timestamp since the schema is identical. **Recommendation:** Use `20250420000002` as-is.

5. **Should `WorkflowState.load/1` also set the process's run key?** If a process loads a snapshot by `session_id`, should it also call `RunKey.set_run_key(session_id)` so subsequent operations target the right namespace? The abandoned branch doesn't do this. **Recommendation:** Yes, `load/1` should set the run key to the `session_id`. This matches the expectation that loading a session means "I am now working on this session."

### 8.2 Risks

| Risk | Mitigation |
|------|-----------|
| `Persistence.Store` could grow into a God-module | Strict entity type enum (`:config \| :workflow_snapshot`), no `:session`. If more entity types are needed, create separate context modules. |
| WorkflowState.save is called too frequently | Add debounce guidance in docs; save should be called at end-of-run or on explicit user action, not on every flag set. |
| `PersistedConfig` is dead code | Flag with TODO marker; easy to remove if confirmed unused after 2 weeks. |
| Migration ordering on existing deployments | Use `mix ecto.migrate` which runs in timestamp order; no conflicts expected. |
| Ecto sandbox test isolation for persistence tests | Use `async: false` + `Ecto.Adapters.SQL.Sandbox.checkout(Repo)` + `delete_all` between tests. |

---

## 9. Effort Estimate

| Task | Hours | Notes |
|------|-------|-------|
| Create `PersistedConfig` schema + migration | 0.5 | Direct port from branch |
| Create `WorkflowSnapshot` schema + migration | 0.5 | Direct port from branch |
| Create `Persistence.Store` (config + snapshot CRUD) | 1.5 | Port from branch, remove `:session` type |
| Add `save/1`, `load/1`, `delete_snapshot/1` to `Workflow.State.Store` | 1.0 | Port logic from branch, adapt to per-run-key |
| Add facade delegations in `Workflow.State` and `WorkflowState` | 0.5 | Thin wrappers |
| Port `persistence/store_test.exs` | 1.0 | 17 tests, remove session CRUD tests |
| Port `workflow_state_test.exs` persistence section | 0.5 | 4 tests + edge cases |
| Run CI gates (compile, format, credo, dialyzer, test) | 0.5 | Iterative fixes |
| **Total** | **6.0** | |

**Comparison:** d-ctj-1 was estimated at 4h but took ~28h. This task is **narrower** (no GenServer, no ETS, no PubSub, no crash recovery) but still carries the risk of test-teardown fragility and Ecto sandbox issues. Padding by 2x for that risk: **~12h worst case**.

**Confidence:** Higher than d-ctj-1 because (a) no GenServer complexity, (b) the abandoned branch's design is sound (just needs scoping adjustments), (c) the schemas and CRUD logic are straightforward Ecto patterns.

---

## Appendix A: Abandoned Branch Architecture vs Current Base

| Aspect | Abandoned Branch | Current Base | Delta |
|--------|-----------------|-------------|-------|
| `persistence.ex` | 315 lines, simpler, raises on error | 406 lines, returns tagged tuples, uses SafeWrite | Base is superior |
| `WorkflowState` | Monolithic Agent, single global namespace | Facade → `Workflow.State` → submodules, per-run isolation | Base is superior |
| Session persistence | Via `Persistence.Store` (`:session`) | Via `SessionStorage.Store` (GenServer + ETS + PubSub) | Base is superior |
| `Workflow.Step` schema | On branch (new) | On base (same) | Identical |
| `PersistedConfig` schema | On branch (new) | Not on base | **Needed** |
| `WorkflowSnapshot` schema | On branch (new) | Not on base | **Needed** |
| `Persistence.Store` | On branch (new) | Not on base | **Needed** (scoped) |
| `WorkflowState.save/load` | On branch (new) | Not on base | **Needed** |

## Appendix B: What the abandoned branch's `persistence.ex` added that the base doesn't have

The branch's `persistence.ex` added `backup/3`, `restore/2`, `list_backups/2` and `read_bytes/2` — convenience file operations not present in Python's `persistence.py`. **Recommendation:** Don't port these. They're not in the Python contract, they're not tested, and they'd add scope. If needed later, they belong in a separate `Persistence.Backup` utility module.
