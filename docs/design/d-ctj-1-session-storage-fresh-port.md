# d-ctj-1: Session Storage Fresh Port — Design

> **Issue**: `code_puppy-ctj.1` (Phase D)
> **Author**: `elixir-programmer-187d1b`
> **Date**: 2025-07-09
> **Status**: Draft — pending shepherd review
> **Supersedes**: Abandoned branch `feature/d-ctj-1-session-storage` @ `cbfb1728`

---

## 1. Python Contract Summary

The canonical contract is `code_puppy/session_storage.py`. The Python bridge (`session_storage_bridge.py`) adds Elixir routing. Together they define the public surface that Elixir must satisfy.

### 1.1 Public Functions

| Function | Return Shape | Persistence | Notes |
|----------|-------------|-------------|-------|
| `save_session(name, history, *, ...)` | `SessionMetadata` dataclass | Elixir-first → file fallback | Upsert; returns `name`, `timestamp`, `message_count`, `total_tokens`, `auto_saved` |
| `save_session_async(name, history, *, ...)` | `None` (fire-and-forget) | Same as `save_session` | ThreadPool in Python; `Task.start` in Elixir. Snapshots history before async dispatch. |
| `load_session(name)` | `SessionHistory` (list of messages) | Elixir-first → file fallback | Returns only messages. |
| `load_session_with_hashes(name)` | `(messages, compacted_hashes)` tuple | Elixir-first → file fallback | Returns both. |
| `list_sessions()` | `list[str]` | Elixir-first → file fallback | Sorted alphabetically. |
| `cleanup_sessions(max_sessions)` | `list[str]` (deleted names) | Elixir-first → file fallback | Keeps newest N. |
| `session_exists(name)` | `bool` | — | (Bridge only) |
| `session_count()` | `int` | — | (Bridge only) |
| `register_terminal(name, *, session_id, cols, rows, shell)` | `dict` | Elixir Store (durable) | Python stores in `_active_terminal` dict + bridge call. |
| `unregister_terminal(name)` | `dict` | Elixir Store (durable) | Clears metadata. |
| `list_terminals()` | `list[dict]` | Elixir Store | Diagnostics. |
| `should_skip_autosave?(history)` | `bool` | Agent state | Debounce (2s) + dedup (fingerprint). |
| `mark_autosave_complete(history)` | `None` | Agent state | Updates tracker after successful save. |

### 1.2 Python-side Subscription Model

**Python does not use per-session PubSub subscriptions.** The Python `session_storage.py` has no `subscribe` or `on_event` mechanism. It uses:
- **Autosave dedup** (module-level globals + `ThreadPoolExecutor`)
- **atexit** handler for shutdown flush
- **Bridge calls** (synchronous JSON-RPC over port)

The per-session PubSub API in the abandoned branch was an Elixir-only addition with **zero Python consumers**. The Python bridge (`session_storage_bridge.py`) never calls `subscribe`, `broadcast`, or `subscribe_all`.

### 1.3 Key Semantics

1. **Elixir-first, file fallback**: `save_session` tries `session_storage_bridge.save_session()` first, falls back to file I/O on any exception.
2. **Terminal metadata passed through**: `save_session` forwards `has_terminal` and `terminal_meta` from `_active_terminal` dict.
3. **Fire-and-forget async**: `save_session_async` returns immediately; errors are logged, never raised to caller.
4. **HMAC integrity** (Python file path only): Not relevant to Elixir path — SQLite is the durable store, not JSON files with HMAC.
5. **Legacy format deserialization**: `_load_raw_bytes` handles JSON+HMAC, msgpack, and rejects pickle. Elixir port doesn't need this — SQLite data is already structured.

---

## 2. Current Elixir Store Inventory

### 2.1 `CodePuppyControl.SessionStorage` (facade, ~300 lines)

**Location**: `elixir/code_puppy_control/lib/code_puppy_control/session_storage.ex`

The facade delegates to `Store` when available, `FileBackend` otherwise. Current public API:

| Function | Store path | FileBackend path | Status |
|----------|-----------|-----------------|--------|
| `save_session/3` | ✅ `Store.save_session/3` | ✅ `FileBackend.save_session/3` | Working |
| `load_session/2` | ✅ `Store.load_session/1` | ✅ `FileBackend.load_session/2` | Working |
| `load_session_full/2` | ✅ `Store.load_session_full/1` | ✅ `FileBackend.load_session_full/2` | Working |
| `update_session/2` | ❌ **FileBackend only** | ✅ | **GAP** — no Store path |
| `delete_session/2` | ✅ `Store.delete_session/1` | ✅ `FileBackend.delete_session/2` | Working |
| `list_sessions/1` | ✅ `Store.list_sessions/0` | ✅ `FileBackend.list_sessions/1` | Working |
| `list_sessions_with_metadata/1` | ✅ `Store.list_sessions_with_metadata/0` | ✅ | Working |
| `search_sessions/1` | ❌ **FileBackend only** | ✅ | **GAP** — no Store path |
| `cleanup_sessions/2` | ✅ `Store.cleanup_sessions/1` | ✅ | Working |
| `export_session/2` | ❌ **FileBackend only** | ✅ | **GAP** — no Store path |
| `export_all_sessions/1` | ❌ **FileBackend only** | ✅ | **GAP** — no Store path |
| `save_session_async/3` | ⚠️ **Forces FileBackend** | ✅ | **BUG** — always calls `FileBackend.safe_resolve_base_dir/1`, injecting `:base_dir`, which forces FileBackend path even when Store is running |
| `subscribe_sessions/0` | ✅ `Store.subscribe_sessions/0` | No-op | Working |
| `subscribe_terminal/0` | ✅ `Store.subscribe_terminal/0` | No-op | Working |
| `register_terminal/2` | ✅ `Store.register_terminal/2` | `{:error, :store_not_available}` | Working |
| `unregister_terminal/1` | ✅ `Store.unregister_terminal/1` | `{:error, :store_not_available}` | Working |
| `session_exists?/2` | ✅ `Store.session_exists?/1` | ✅ | Working |
| `count_sessions/1` | ✅ `Store.count_sessions/0` | ✅ | Working |
| `should_skip_autosave?/1` | ✅ `AutosaveTracker` | ✅ | Working |
| `mark_autosave_complete/1` | ✅ `AutosaveTracker` | ✅ | Working |

**No per-session PubSub** in current facade — only global `"sessions:events"` topic via `subscribe_sessions/0`.

### 2.2 `CodePuppyControl.SessionStorage.Store` (GenServer, ~290 lines)

**Location**: `elixir/code_puppy_control/lib/code_puppy_control/session_storage/store.ex`

- **ETS tables**: `:session_store_ets` (sessions), `:session_terminal_ets` (terminals)
- **SQLite**: via `CodePuppyControl.Sessions` (Ecto context)
- **PubSub topics**: `"sessions:events"`, `"terminal:recovery"`
- **Write-through ordering**: SQLite → ETS → PubSub (crash-safe)
- **Read path**: ETS (O(1)) → SQLite (cache miss)
- **Init**: Rebuilds ETS from SQLite; defers terminal recovery via `handle_continue`

**PubSub events emitted on `"sessions:events"`:**
- `{:session_saved, name, metadata_map}` — after successful write
- `{:session_deleted, name}` — after deletion
- `{:sessions_cleaned, deleted_names}` — after cleanup

**PubSub events emitted on `"terminal:recovery"`:**
- `{:terminal_registered, name}`
- `{:terminal_unregistered, name}`
- `{:terminal_recovered, name, meta}`
- `{:terminal_recovery_failed, name, reason}`

**Missing Store functions:**
- No `update_session/2` (metadata-only update without rewriting history)
- No `search_sessions/1` (filtering by name/tokens/time)
- No `export_session/2` / `export_all_sessions/1`

### 2.3 `CodePuppyControl.SessionStorage.StoreHelpers` (~180 lines)

Pure functions: `build_entry/8`, `chat_session_to_entry/1`, `session_data_to_entry/2`, `session_to_result/1`, `resolve_terminal_fields/3`, `normalize_meta_keys/1`, `get_key/4`, `now_iso/0`.

### 2.4 `CodePuppyControl.SessionStorage.FileBackend` (~350 lines)

File-based JSON storage under `~/.code_puppy_ex/sessions/`. Used as fallback when Store isn't running (standalone scripts, tests with `:base_dir` overrides). Has complete CRUD, search, cleanup, and export.

### 2.5 `CodePuppyControl.SessionStorage.AutosaveTracker` (~100 lines)

Agent tracking debounce (2s window) and dedup (fingerprint). Injectable `time_fn` for testing.

### 2.6 `CodePuppyControl.SessionStorage.TerminalRecovery` (~150 lines)

Crash recovery for PTY sessions. Deferred via `handle_continue`; retry with exponential backoff up to 5 attempts.

### 2.7 `CodePuppyControl.Sessions` (Ecto context, ~170 lines)

SQLite persistence layer. CRUD via Ecto. `ChatSession` schema with `has_terminal`, `terminal_meta` fields. `update_terminal_meta/3` for durable terminal metadata updates.

### 2.8 Supervision Tree Position

```
Application children (relevant slice):
  ...
  {Phoenix.PubSub, name: CodePuppyControl.PubSub},     # 4
  CodePuppyControl.EventStore,                          # 5
  CodePuppyControl.SessionStorage.Store,                # 5a
  CodePuppyControl.SessionStorage.AutosaveTracker,      # 5b
  ...
  CodePuppyControl.PtyManager,                          # 22
  ...
```

Store starts before AutosaveTracker. PtyManager starts after Store (hence deferred terminal recovery).

---

## 3. Test Contracts from Abandoned Branch

### 3.1 `session_storage_pubsub_test.exs` (21 tests)

**What it asserts:**
1. Per-session `subscribe(name)` / `unsubscribe(name)` — subscribe to topic `"session:<name>"`
2. Global `subscribe_all()` / `unsubscribe_all()` — subscribe to topic `"sessions:all"`
3. `broadcast(name, type, payload)` — emits `{:session_event, %{type:, session_name:, timestamp:, payload:}}` to both per-session and global topics
4. `broadcast_local/3` — same, but local-node only
5. ETS cache integration via `SessionStorage.ETSCache` — `save_session` populates `ETSCache`, `load_session` hits `ETSCache`, `delete_session` invalidates `ETSCache`
6. Event-driven cache invalidation — `ETSCache` subscribes to `"sessions:all"` and auto-updates
7. `:session_loaded` events with `from_cache: true/false` payload
8. `save_session_async/3` with `:broadcast` option
9. `list_sessions/1` with `:prefer_cache` option
10. Cache TTL (30 min) and `invalidate_stale/0` cleanup
11. Event type enumeration (`:session_created`, `:session_updated`, `:session_deleted`, custom)

**Assessment**: These tests encode an architecture with **two ETS caches** (Store's `:session_store_ets` + ETSCache's three tables). The per-session PubSub API (`subscribe/1`, `broadcast/3`) is useful but was never consumed by Python. The `ETSCache` is entirely redundant with Store's ETS tables.

### 3.2 `session_storage_async_test.exs` (15 tests)

**What it asserts:**
1. `save_session_async/3` returns `:ok` synchronously
2. Session persists to disk after background Task completes
3. Errors logged, not raised (fire-and-forget)
4. `base_dir/0` raise guarded (fire-and-forget contract)
5. Explicit `:base_dir` skips `base_dir/0` evaluation
6. History snapshot isolation (immutable in Elixir — intent test)
7. `base_dir` captured before Task spawn (env teardown race)
8. AutosaveTracker: fresh state → don't skip
9. AutosaveTracker: within debounce → skip
10. AutosaveTracker: past debounce, same fingerprint → skip (dedup)
11. AutosaveTracker: past debounce, different fingerprint → don't skip
12. AutosaveTracker: empty history stable fingerprint
13. AutosaveTracker: `mark_autosave_complete` returns `:ok`
14. AutosaveTracker: successive marks update fingerprint
15. (Repeat of debounce/dedup with controlled clock)

**Assessment**: These tests are **identical to the current base**. The abandoned branch didn't change the async test file. All 15 tests port as-is.

### 3.3 `session_storage_test.exs` (base: ~26.4 KB, branch: ~26.5 KB)

The branch version is nearly identical to the base. No new test cases were added beyond the PubSub and ETS cache tests (which live in separate files).

---

## 4. Gap Analysis

| # | Capability | Python `session_storage` | Elixir Store (current base) | Gap |
|---|-----------|------------------------|---------------------------|-----|
| 1 | **Save session** | `save_session()` → dict | `Store.save_session/3` → `{:ok, map}` | ✅ None — facade wraps return shape |
| 2 | **Load session** | `load_session()` → list | `Store.load_session/1` → `{:ok, %{history:, compacted_hashes:}}` | ✅ None — facade transforms |
| 3 | **Load with hashes** | `load_session_with_hashes()` → tuple | Same as above | ✅ None |
| 4 | **Per-session PubSub** | *(not used by Python)* | Store emits `"sessions:events"` only | **GAP** — no per-session topics. Python doesn't need them, but Elixir consumers (LiveView, channels) may. |
| 5 | **Global PubSub** | *(not used)* | Store emits `"sessions:events"` | **GAP** — exists but event shape differs from what abandoned branch tests expect (`{:session_event, map}` vs `{:session_saved, name, meta}`) |
| 6 | **Async save** | `save_session_async` → None | Facade forces FileBackend path | **BUG** — `save_session_async/3` always uses `FileBackend.safe_resolve_base_dir/1`, injecting `:base_dir`, which forces FileBackend even when Store is running |
| 7 | **Update metadata** | `update_session()` → dict | **No Store path** — facade delegates to FileBackend only | **GAP** — `Store.update_session/2` doesn't exist |
| 8 | **Search sessions** | *(Python has no search — only list/cleanup)* | `FileBackend.search_sessions/1` only | **SCOPE QUESTION** — Python doesn't need search; Elixir has it via FileBackend. Port to Store? Or descope? |
| 9 | **Export session** | *(Python has no export)* | `FileBackend` only | **SCOPE QUESTION** — same as search |
| 10 | **Delete session** | `cleanup_sessions()` | `Store.delete_session/1` | ✅ Working |
| 11 | **Terminal tracking** | `register_terminal/unregister_terminal` | `Store.register_terminal/2`, `Store.unregister_terminal/1` | ✅ Working |
| 12 | **Autosave debounce** | `should_skip_autosave/mark_autosave_complete` | `AutosaveTracker` Agent | ✅ Working |
| 13 | **Second ETS cache** | *(N/A)* | Abandoned branch added `ETSCache` GenServer | **ANTI-PATTERN** — redundant with Store's ETS; confirmed delete |

---

## 5. Proposed Design

### 5.1 Module Layout

```
lib/code_puppy_control/
  session_storage.ex                    # Facade (target: ~400 lines)
  session_storage/
    store.ex                            # GenServer (ETS + SQLite + PubSub) — ~300 lines
    store_helpers.ex                    # Pure helpers — ~180 lines
    file_backend.ex                     # File-based fallback — ~350 lines (unchanged)
    format.ex                          # Path/format constants — ~50 lines (unchanged)
    autosave_tracker.ex                 # Debounce/dedup Agent — ~100 lines (unchanged)
    terminal_recovery.ex                # Crash recovery — ~150 lines (unchanged)
    migrator.ex                         # Python → Elixir migration — (unchanged)
    pubsub.ex                           # NEW: per-session PubSub helpers — ~80 lines
```

**Rationale**: Extracting `SessionStorage.PubSub` keeps the facade under the 600-line cap. The PubSub module is pure helper code (topic construction, broadcast wrapping) with no state.

### 5.2 PubSub Topic Strategy

**Recommendation: Store emits per-session topics directly.**

The Store GenServer already broadcasts on `"sessions:events"` after every write. We add a second broadcast on `"session:{name}"` in the same `handle_call` callback, right after the global broadcast. This is:

1. **Zero additional latency** — same process, same transaction boundary
2. **No split-brain** — Store is the single source; facade doesn't need a fan-out subscriber
3. **Simple** — `Phoenix.PubSub.broadcast(@pubsub, "session:#{name}", event)` is one line

**Topic taxonomy:**

| Topic | Who emits | Who subscribes | Event shape |
|-------|-----------|---------------|-------------|
| `"sessions:events"` | Store | LiveView, channels, internal subscribers | `{:session_saved, name, meta}` / `{:session_deleted, name}` / `{:sessions_cleaned, names}` *(unchanged)* |
| `"session:{name}"` | Store | Per-session subscribers (LiveView, channels) | `{:session_event, %{type:, session_name:, timestamp:, payload:}}` *(new, matches abandoned branch contract)* |
| `"terminal:recovery"` | Store, TerminalRecovery | Terminal subscribers | `{:terminal_registered, name}` etc. *(unchanged)* |

**New Store behavior in `handle_call({:save_session, ...})`:**
```elixir
# After existing global broadcast:
Phoenix.PubSub.broadcast(@pubsub, @sessions_topic,
  {:session_saved, name, Map.drop(entry, [:history])})

# NEW: per-session broadcast
Phoenix.PubSub.broadcast(@pubsub, "session:#{name}",
  {:session_event, %{
    type: :session_saved,
    session_name: name,
    timestamp: DateTime.utc_now(),
    payload: Map.drop(entry, [:history])
  }})
```

Same pattern for `delete_session` and `cleanup_sessions`.

**New facade functions** (delegating to `SessionStorage.PubSub`):
- `subscribe(name)` — `Phoenix.PubSub.subscribe(@pubsub, "session:#{name}")`
- `unsubscribe(name)` — `Phoenix.PubSub.unsubscribe(@pubsub, "session:#{name}")`
- `subscribe_all()` — `Phoenix.PubSub.subscribe(@pubsub, "sessions:events")`
- `unsubscribe_all()` — `Phoenix.PubSub.unsubscribe(@pubsub, "sessions:events")`
- `broadcast(name, type, payload)` — manual broadcast for custom events
- `broadcast_local(name, type, payload)` — local-node variant

**Note**: `subscribe_all/0` subscribes to the existing `"sessions:events"` topic (with the Store's existing event shape), NOT a new `"sessions:all"` topic. This avoids a third topic. Consumers of `subscribe_all` receive `{:session_saved, ...}` tuples, not `{:session_event, ...}` maps. This is a **deliberate departure** from the abandoned branch's `"sessions:all"` topic with `{:session_event, ...}` shape. The two event shapes serve different purposes:

- `{:session_saved, name, meta}` — lightweight lifecycle signals (existing)
- `{:session_event, %{type:, ...}}` — richer per-session events (new)

**Why not unify?** Changing the existing `"sessions:events"` event shape would break existing subscribers (LiveView channels, TUI). Adding a parallel topic adds confusion. The cleanest approach is: existing topic stays as-is; per-session topics carry richer events.

### 5.3 Async Save

**Recommendation: `save_session_async/3` delegates to `save_session/3` which delegates to Store when available.**

Current bug: `save_session_async/3` always calls `FileBackend.safe_resolve_base_dir/1`, which injects `:base_dir` into opts, which forces the facade's `store_available?()` check to return `false` (because `Keyword.has_key?(opts, :base_dir)` is true), routing to FileBackend even when Store is running.

**Fix:**

```elixir
def save_session_async(name, history, opts \\ []) do
  history_snapshot = history

  # Resolve base_dir eagerly (before Task spawn) ONLY if not already
  # provided and Store is NOT available. When Store is available,
  # save_session/3 will route to Store without needing :base_dir.
  opts_resolved =
    if store_available?() do
      # Store path — no :base_dir needed
      opts
    else
      # FileBackend path — resolve base_dir eagerly
      case FileBackend.safe_resolve_base_dir(opts) do
        {:ok, dir} -> Keyword.put(opts, :base_dir, dir)
        {:error, reason} ->
          Logger.warning("Async session save skipped: #{inspect(reason)}")
          nil
      end
    end

  if opts_resolved do
    _ =
      Task.start(fn ->
        case save_session(name, history_snapshot, opts_resolved) do
          {:ok, _meta} -> mark_autosave_complete(history_snapshot)
          {:error, reason} -> Logger.warning("Async session save failed: #{inspect(reason)}")
        end
      end)
    :ok
  else
    :ok
  end
end
```

This preserves the existing fire-and-forget contract, the env-teardown-race protection (base_dir resolved before Task.spawn when Store is unavailable), and correctly routes to Store when available.

### 5.4 FileBackend Fate

**Recommendation: Keep as test-only / offline fallback. No changes.**

FileBackend serves two legitimate purposes:
1. **Test isolation**: Tests with `:base_dir` overrides use FileBackend to avoid touching SQLite/Store.
2. **Offline mode**: Standalone scripts running outside the OTP supervision tree.

FileBackend is NOT deleted. However, the facade must route to Store whenever Store is available and `:base_dir` is not explicitly provided. The current facade already does this for most functions — we just need to fix the gaps (`update_session`, `search_sessions`, `export_*`, `save_session_async`).

### 5.5 ETSCache Fate

**Confirmed deleted.** The abandoned branch's `ETSCache` GenServer (3 ETS tables: `:session_metadata_cache`, `:session_history_cache`, `:session_hashes_cache`) is **entirely redundant** with Store's `:session_store_ets` table. It was the root cause of the split-brain issues flagged by shepherd. No code from `ets_cache.ex` carries forward.

### 5.6 New Store Functions

#### `Store.update_session/2`

**Why**: The facade's `update_session/2` currently only routes to FileBackend. When Store is available, we need a Store-backed metadata update that doesn't require rewriting the full history.

**Signature**:
```elixir
@spec update_session(session_name(), keyword()) ::
        {:ok, session_metadata()} | {:error, term()}
def update_session(name, opts) do
  GenServer.call(__MODULE__, {:update_session, name, opts})
end
```

**Implementation** (in `handle_call`):
1. Read current ETS entry
2. Apply opts (`:auto_saved`, `:total_tokens`, `:timestamp`) to the entry
3. Update SQLite via `Sessions.save_session(name, entry.history, ...)` with merged opts
4. Update ETS entry
5. Broadcast on both `"sessions:events"` and `"session:{name}"`

**Returns** `{:error, :not_found}` if session doesn't exist in ETS.

#### `Store.search_sessions/1`

**Why**: FileBackend has search; Store-backed search is useful for the session browser widget. When Store is available, search should operate on ETS (no disk I/O).

**Signature**:
```elixir
@spec search_sessions(keyword()) :: {:ok, [session_metadata()]}
def search_sessions(opts) do
  # Pure ETS read + filter — no GenServer call needed
  entries =
    @session_table
    |> :ets.tab2list()
    |> Enum.map(fn {_, e} -> e end)

  filtered =
    entries
    |> filter_by_name(Keyword.get(opts, :name_pattern))
    |> filter_by_auto_saved(Keyword.get(opts, :auto_saved))
    |> filter_by_token_range(Keyword.get(opts, :min_tokens), Keyword.get(opts, :max_tokens))
    |> filter_by_time_range(Keyword.get(opts, :since), Keyword.get(opts, :until))
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(Keyword.get(opts, :limit, 100))

  {:ok, Enum.map(filtered, &store_entry_to_metadata/1)}
end
```

Filter helpers are pure functions — add to `StoreHelpers` to keep Store under 600 lines.

#### `Store.export_session/2` and `Store.export_all_sessions/1`

**Recommendation: Descope from Store.** Export is a read-only operation that formats data as JSON. When Store is available, `export_session/2` can compose `Store.load_session_full/1` + `Jason.encode!/2`. This is a **facade-level composition**, not a Store primitive.

```elixir
# In facade:
def export_session(name, opts \\ []) do
  if store_available?() and not Keyword.has_key?(opts, :base_dir) do
    case Store.load_session_full(name) do
      {:ok, entry} ->
        data = %{
          "format" => Format.current_format(),
          "payload" => %{
            "messages" => entry.history,
            "compacted_hashes" => entry.compacted_hashes
          },
          "metadata" => %{
            "session_name" => entry.name,
            "timestamp" => entry.timestamp,
            "message_count" => entry.message_count,
            "total_tokens" => entry.total_tokens,
            "auto_saved" => entry.auto_saved
          }
        }
        json = Jason.encode!(data, pretty: true)
        write_or_return(json, Keyword.get(opts, :output_path))

      {:error, reason} -> {:error, reason}
    end
  else
    FileBackend.export_session(name, opts)
  end
end
```

Same pattern for `export_all_sessions/1` — compose from `Store.list_sessions_with_metadata/0` + `Store.load_session_full/1`.

### 5.7 Public Facade API

The complete facade API after the fresh port:

| Function | Signature | Store? | FileBackend? |
|----------|-----------|--------|-------------|
| `save_session/3` | `(name, history, opts) → {:ok, meta} \| {:error, _}` | ✅ | ✅ |
| `load_session/2` | `(name, opts) → {:ok, %{messages:, compacted_hashes:}} \| {:error, _}` | ✅ | ✅ |
| `load_session_full/2` | `(name, opts) → {:ok, data} \| {:error, _}` | ✅ | ✅ |
| `update_session/2` | `(name, opts) → {:ok, meta} \| {:error, _}` | ✅ **NEW** | ✅ |
| `delete_session/2` | `(name, opts) → :ok \| {:error, _}` | ✅ | ✅ |
| `list_sessions/1` | `(opts) → {:ok, [name]} \| {:error, _}` | ✅ | ✅ |
| `list_sessions_with_metadata/1` | `(opts) → {:ok, [meta]} \| {:error, _}` | ✅ | ✅ |
| `search_sessions/1` | `(opts) → {:ok, [meta]} \| {:error, _}` | ✅ **NEW** | ✅ |
| `cleanup_sessions/2` | `(max, opts) → {:ok, [name]} \| {:error, _}` | ✅ | ✅ |
| `export_session/2` | `(name, opts) → {:ok, json\|path} \| {:error, _}` | ✅ **NEW** | ✅ |
| `export_all_sessions/1` | `(opts) → {:ok, json\|path} \| {:error, _}` | ✅ **NEW** | ✅ |
| `save_session_async/3` | `(name, history, opts) → :ok` | ✅ **FIXED** | ✅ |
| `session_exists?/2` | `(name, opts) → boolean` | ✅ | ✅ |
| `count_sessions/1` | `(opts) → non_neg_integer` | ✅ | ✅ |
| `subscribe/1` | `(name) → :ok \| {:error, _}` | ✅ **NEW** | N/A |
| `unsubscribe/1` | `(name) → :ok \| {:error, _}` | ✅ **NEW** | N/A |
| `subscribe_all/0` | `() → :ok \| {:error, _}` | ✅ **NEW** | N/A |
| `unsubscribe_all/0` | `() → :ok \| {:error, _}` | ✅ **NEW** | N/A |
| `broadcast/3` | `(name, type, payload) → :ok` | ✅ **NEW** | N/A |
| `broadcast_local/3` | `(name, type, payload) → :ok` | ✅ **NEW** | N/A |
| `subscribe_sessions/0` | `() → :ok \| {:error, _}` | ✅ | N/A |
| `subscribe_terminal/0` | `() → :ok \| {:error, _}` | ✅ | N/A |
| `register_terminal/2` | `(name, meta) → :ok \| {:error, _}` | ✅ | `{:error, :store_not_available}` |
| `unregister_terminal/1` | `(name) → :ok \| {:error, _}` | ✅ | `{:error, :store_not_available}` |
| `list_terminal_sessions/0` | `() → [map]` | ✅ | `[]` |
| `should_skip_autosave?/1` | `(history) → boolean` | ✅ | ✅ |
| `mark_autosave_complete/1` | `(history) → :ok` | ✅ | ✅ |
| `base_dir/0` | `() → Path.t()` | — | ✅ |
| `ensure_dir/0` | `() → {:ok, Path} \| {:error, _}` | — | ✅ |

### 5.8 New `SessionStorage.PubSub` Module

Extracted from facade to keep under 600-line cap. Pure helper module, no state.

```elixir
defmodule CodePuppyControl.SessionStorage.PubSub do
  @moduledoc """
  Per-session and global PubSub helpers for SessionStorage.

  Topic taxonomy:
  - "session:{name}" — per-session events
  - "sessions:events" — global lifecycle events (from Store)
  - "terminal:recovery" — terminal recovery events (from Store)

  Event shapes:
  - Per-session: {:session_event, %{type:, session_name:, timestamp:, payload:}}
  - Global: {:session_saved, name, meta} | {:session_deleted, name} | ...
  """

  @pubsub CodePuppyControl.PubSub
  @session_topic_prefix "session:"

  @spec session_topic(String.t()) :: String.t()
  def session_topic(name), do: "#{@session_topic_prefix}#{name}"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(name) do
    Phoenix.PubSub.subscribe(@pubsub, session_topic(name))
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(name) do
    Phoenix.PubSub.unsubscribe(@pubsub, session_topic(name))
  end

  @spec broadcast(String.t(), atom(), map()) :: :ok
  def broadcast(name, type, payload) do
    event = %{
      type: type,
      session_name: name,
      timestamp: DateTime.utc_now(),
      payload: payload
    }
    Phoenix.PubSub.broadcast(@pubsub, session_topic(name), {:session_event, event})
    :ok
  end

  @spec broadcast_local(String.t(), atom(), map()) :: :ok
  def broadcast_local(name, type, payload) do
    event = %{
      type: type,
      session_name: name,
      timestamp: DateTime.utc_now(),
      payload: payload
    }
    Phoenix.PubSub.local_broadcast(@pubsub, session_topic(name), {:session_event, event})
    :ok
  end
end
```

---

## 6. Test Plan

### 6.1 Tests from Abandoned Branch — Port As-Is

These tests encode valid contracts that the fresh design must satisfy:

| Test | From | Changes Needed |
|------|------|---------------|
| `save_session_async/3` returns `:ok` synchronously | `session_storage_async_test.exs` | None — identical on base |
| Async save persists to disk | `session_storage_async_test.exs` | None |
| Fire-and-forget on `base_dir` raise | `session_storage_async_test.exs` | None |
| Explicit `:base_dir` skips `base_dir/0` | `session_storage_async_test.exs` | None |
| History snapshot isolation | `session_storage_async_test.exs` | None |
| `base_dir` captured before Task spawn | `session_storage_async_test.exs` | None |
| All 7 AutosaveTracker tests | `session_storage_async_test.exs` | None — uses isolated tracker instances |
| Per-session subscribe/unsubscribe | `session_storage_pubsub_test.exs` | **Rewrite** — use `SessionStorage.PubSub` instead of `SessionStorage.ETSCache` |
| Global subscribe/unsubscribe | `session_storage_pubsub_test.exs` | **Rewrite** — use `"sessions:events"` topic, not `"sessions:all"` |
| Broadcast to session subscribers | `session_storage_pubsub_test.exs` | **Rewrite** — event shape changes |
| Custom event broadcast | `session_storage_pubsub_test.exs` | **Port** — `SessionStorage.broadcast/3` still works |

### 6.2 Tests from Abandoned Branch — Need Rewriting

| Test | Why Rewrite |
|------|-------------|
| ETS cache population (`ETSCache.get_session`) | **Delete** — no ETSCache. Replace with `Store.load_session/1` reads. |
| ETS cache hit/miss (`ETSCache.clear()` then reload) | **Delete** — not applicable. Store's ETS is internal; test via `Store.load_session/1` timing, not cache manipulation. |
| ETS cache invalidation on delete | **Rewrite** — test that `Store.load_session/1` returns `{:error, :not_found}` after delete. |
| Event-driven cache auto-update | **Delete** — ETSCache subscribed to `"sessions:all"`. Store's ETS updates inline; no separate subscriber needed. |
| `session_loaded` with `from_cache: true/false` | **Descope** — the `from_cache` payload was an ETSCache artifact. Store's read path is ETS-first with SQLite fallback; consumers don't get a `from_cache` signal. |
| `save_session_async` with `:broadcast` option | **Rewrite** — remove `:broadcast` / `:skip_broadcast` options from `save_session_async/3`. Store always broadcasts; opt-out is unnecessary complexity. |
| `list_sessions` with `:prefer_cache` option | **Delete** — no ETSCache to prefer. Store path always uses ETS. |
| Cache TTL / `invalidate_stale/0` | **Delete** — no ETSCache TTL. Store's ETS is rebuilt from SQLite on init; entries are managed inline. |

### 6.3 New Tests Required

| Test | What It Asserts |
|------|----------------|
| `Store.update_session/2` updates metadata in ETS + SQLite | After `update_session`, `Store.load_session_full/1` returns updated values; SQLite row matches. |
| `Store.update_session/2` returns `{:error, :not_found}` for missing session | Clean error on nonexistent session. |
| `Store.update_session/2` broadcasts on per-session topic | `subscribe(name)` receives `{:session_event, %{type: :session_updated}}`. |
| `Store.search_sessions/1` filters by name pattern | Regex and string patterns work against ETS entries. |
| `Store.search_sessions/1` filters by token range / time range | Combinatorial filtering. |
| Facade `search_sessions/1` routes to Store when available | No `FileBackend` call when Store is running. |
| Facade `export_session/2` composes from Store when available | Returns JSON with correct format/payload/metadata shape. |
| Facade `export_all_sessions/1` composes from Store when available | Returns JSON array. |
| Facade `save_session_async/3` routes to Store when available | Verify session lands in SQLite (not FileBackend) after async save. |
| Per-session broadcast after Store save | `subscribe(name)` → `save_session` → receive `{:session_event, %{type: :session_saved}}`. |
| Per-session broadcast after Store delete | `subscribe(name)` → `delete_session` → receive `{:session_event, %{type: :session_deleted}}`. |
| `subscribe_all/0` receives Store lifecycle events | `subscribe_all()` → `save_session` → receive `{:session_saved, name, meta}`. |
| `broadcast/3` for custom events | `subscribe(name)` → `broadcast(name, :custom, %{})` → receive. |
| `update_session/2` facade routes to Store when available | No FileBackend call when Store is running. |

### 6.4 Test File Organization

```
test/code_puppy_control/
  session_storage_test.exs          # Existing CRUD tests — extend with Store-path tests
  session_storage_async_test.exs    # Existing — minimal changes (fix save_session_async routing)
  session_storage_pubsub_test.exs   # NEW — per-session PubSub + Store PubSub integration
  session_storage/
    format_test.exs                 # Existing — unchanged
    migrator_test.exs              # Existing — unchanged
```

---

## 7. Risks and Open Questions

### 7.1 Needs Architect Input

| # | Question | Why |
|---|----------|-----|
| Q1 | **Should per-session PubSub topics be part of the Python bridge contract?** Currently Python doesn't subscribe to any PubSub events. If a future Python consumer needs real-time session notifications, the bridge would need a subscription mechanism (long-poll or WebSocket). This is out of scope for this issue but worth flagging. | Architectural — affects bridge API surface |
| Q2 | **Should `subscribe_all/0` use `"sessions:events"` or a new `"sessions:all"` topic?** The abandoned branch used `"sessions:all"` with `{:session_event, ...}` shape. I recommend reusing `"sessions:events"` with its existing `{:session_saved, ...}` shape to avoid breaking existing subscribers. But this means `subscribe_all/0` returns different event shapes than `subscribe/1`. | Consumer-facing API decision |

### 7.2 Migration Risk

**No migration needed from FileBackend to Store.** The FileBackend format and SQLite schema are independent. The `SessionStorage.Migrator` module already handles migrating Python `~/.code_puppy/` sessions to Elixir `~/.code_puppy_ex/`. No new migration path is needed because:

1. FileBackend sessions (under `~/.code_puppy_ex/sessions/`) continue to exist independently.
2. Store sessions live in SQLite (separate from FileBackend files).
3. When Store is running, new writes go to SQLite; FileBackend files are not created.
4. On Store init, ETS is rebuilt from SQLite — FileBackend files are not read.

**Edge case**: If a session was saved via FileBackend (Store was down), then Store starts — the session won't appear in Store until it's re-saved. This is **acceptable** — FileBackend sessions are the fallback path and don't need to be imported into Store.

### 7.3 Backwards Compatibility with Python Bridge

The Python bridge (`session_storage_bridge.py`) calls these Elixir transport methods:

| Bridge method | Elixir handler | Return shape | Status |
|---------------|---------------|-------------|--------|
| `session_save(name, history, ...)` | `Store.save_session/3` | `{name, message_count, total_tokens, ...}` | ✅ Working |
| `session_load(name)` | `Store.load_session/1` | `{history, compacted_hashes}` | ✅ Working |
| `session_load_full(name)` | `Store.load_session_full/1` | Full session map | ✅ Working |
| `session_list()` | `Store.list_sessions/0` | `[name]` | ✅ Working |
| `session_list_with_metadata()` | `Store.list_sessions_with_metadata/0` | `[meta]` | ✅ Working |
| `session_delete(name)` | `Store.delete_session/1` | `:ok` | ✅ Working |
| `session_cleanup(max)` | `Store.cleanup_sessions/1` | `{deleted_names}` | ✅ Working |
| `session_exists(name)` | `Store.session_exists?/1` | `boolean` | ✅ Working |
| `session_count()` | `Store.count_sessions/0` | `integer` | ✅ Working |
| `session_register_terminal(name, ...)` | `Store.register_terminal/2` | `:ok` | ✅ Working |
| `session_unregister_terminal(name)` | `Store.unregister_terminal/1` | `:ok` | ✅ Working |
| `session_list_terminals()` | `Store.list_terminal_sessions/0` | `[meta]` | ✅ Working |

**No bridge changes needed.** The Python bridge already routes through Store when available. The new facade functions (`subscribe`, `broadcast`, `update_session`, `search_sessions`, `export_*`) are Elixir-only — no Python consumer exists.

### 7.4 `:skip_broadcast` Option

The abandoned branch added `:skip_broadcast` to `save_session/3` and `update_session/2`. **Recommendation: Remove this option.** Store always broadcasts — opt-out creates split-brain risk (consumer subscribes but never gets events for certain writes). If a test needs to avoid PubSub noise, it should use a separate test topic or test the Store directly without subscribing.

### 7.5 `save_session_async/3` `:broadcast` Option

Same reasoning — **remove**. When Store is available, `save_session_async/3` calls `save_session/3`, which routes to Store, which always broadcasts. No opt-out.

---

## 8. Effort Estimate

| Phase | Description | Hours |
|-------|-------------|-------|
| **P1** | Add per-session PubSub to Store (broadcast on `"session:{name}"` after every write) | 1.5h |
| **P2** | Create `SessionStorage.PubSub` module + wire into facade (`subscribe/1`, `broadcast/3`, etc.) | 1h |
| **P3** | Add `Store.update_session/2` (GenServer call + ETS + SQLite + PubSub) | 1.5h |
| **P4** | Add `Store.search_sessions/1` (pure ETS filter, helpers in StoreHelpers) | 1h |
| **P5** | Fix `save_session_async/3` routing (Store-first, not FileBackend-forced) | 0.5h |
| **P6** | Add Store-backed `export_session/2` and `export_all_sessions/1` in facade | 0.5h |
| **P7** | Wire `update_session/2`, `search_sessions/1` in facade to route to Store | 0.5h |
| **P8** | Remove `:skip_broadcast` / `:broadcast` options from facade | 0.5h |
| **P9** | Write `session_storage_pubsub_test.exs` (new file, ~15 tests) | 2h |
| **P10** | Extend `session_storage_test.exs` with Store-path tests (~8 tests) | 1.5h |
| **P11** | Extend `session_storage_async_test.exs` with Store-routing test (1-2 tests) | 0.5h |
| **P12** | CI gate: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix test` | 1h |
| **Total** | | **~12h** |

**Risk buffer**: +3h for test flakiness (async timing), Dialyzer fixes, or unexpected Store edge cases.

**Total with buffer**: ~15h

---

## Appendix A: Abandoned Branch Problems (for reference)

| # | Problem | Root Cause | Fix in Fresh Port |
|---|---------|-----------|-------------------|
| 1 | Two ETS caches coexist | `ETSCache` GenServer added alongside Store's `:session_store_ets` | Delete `ETSCache`; Store is the only cache |
| 2 | Per-session PubSub API subscribes to topics Store doesn't emit | `subscribe(name)` → `"session:<name>"` topic, but Store only emits on `"sessions:events"` | Store emits on `"session:{name}"` too |
| 3 | `save_session_async/3` forces FileBackend path | Always calls `FileBackend.safe_resolve_base_dir/1`, injects `:base_dir` | Route to Store when available; only resolve `base_dir` when Store unavailable |
| 4 | `update_session/2` hardcoded to FileBackend | No `Store.update_session/2` exists | Add `Store.update_session/2` |
| 5 | `search_sessions/1` hardcoded to FileBackend | No `Store.search_sessions/1` exists | Add `Store.search_sessions/1` (pure ETS) |
| 6 | `export_*` hardcoded to FileBackend | No Store composition in facade | Add Store composition in facade |
| 7 | `:skip_broadcast` option creates split-brain | Caller can suppress PubSub events that other subscribers expect | Remove `:skip_broadcast` option |

## Appendix B: Python `session_storage.py` Function Map (for reference)

```
save_session(name, history, *, base_dir, timestamp, token_estimator, auto_saved, compacted_hashes, precomputed_total)
  → tries session_storage_bridge.save_session() first
  → falls back to file I/O (JSON + HMAC)

save_session_async(*, history, session_name, base_dir, timestamp, token_estimator, auto_saved, compacted_hashes, precomputed_total)
  → ThreadPoolExecutor(max_workers=1)
  → calls save_session() in background thread
  → snapshots history before dispatch

load_session(session_name, base_dir=None, *, allow_legacy=False)
  → tries session_storage_bridge.load_session() first
  → falls back to file I/O

load_session_with_hashes(session_name, base_dir=None)
  → same as load_session but returns (messages, compacted_hashes)

list_sessions(base_dir=None)
  → tries session_storage_bridge.list_sessions() first
  → falls back to file glob

cleanup_sessions(base_dir=None, max_sessions=10)
  → tries session_storage_bridge.cleanup_sessions() first
  → falls back to file-based cleanup

register_terminal_session(name, session_id, cols, rows, shell)
  → stores in _active_terminal dict
  → calls session_storage_bridge.register_terminal()

unregister_terminal_session(name)
  → removes from _active_terminal dict
  → calls session_storage_bridge.unregister_terminal()

get_active_terminals()
  → returns dict(_active_terminal)

should_skip_autosave(history)
mark_autosave_complete(history)

restore_autosave_interactively(base_dir)
  → interactive prompt_toolkit menu (Python-only, not ported)
```
