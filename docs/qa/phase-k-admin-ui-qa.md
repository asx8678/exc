# Phase K Admin UI / Runtime / Dogfood QA

> **Date:** 2026-05-04
> **Issue:** code-puppy-530.4
> **Method:** Playwright headless Chromium (revision 1217) + curl + CLI smoke
> **Phoenix:** `http://127.0.0.1:4000`, MIX_ENV=dev, PID 87534

---

## 1. Admin UI Browser QA

### Method

Playwright headless Chromium 147.0.7727.15 (revision 1217), 1280×720 viewport,
2-second post-load wait for LiveView websocket connection. Each route checked
for: HTTP status, page title, heading/body indicator, LiveView markers
(`phx-attributes`, `data-phx-session`, `data-phx-static`, `live-container`),
console errors, and secret exposure patterns.

### Route Table

| Route | Status | LiveView | Title/Heading | Console Errors | Secrets |
|-------|--------|----------|---------------|----------------|---------|
| `/` | 200 | — | JSON status payload | 0 | none |
| `/health` | 200 | — | JSON health payload | 0 | none |
| `/health/runtime` | 200 | — | JSON runtime payload (ports, processes, memory) | 0 | none |
| `/admin/` | 200 | ✅ | h1: Dashboard | 0 | none |
| `/admin/agents` | 200 | ✅ | h1: Agents | 0 | none |
| `/admin/jobs` | 200 | ✅ | h1: Jobs | 0 | none |
| `/admin/worktrees` | 200 | ✅ | h1: Worktrees | 0 | none |
| `/admin/pack` | 200 | ✅ | h1: Pack | 0 | none |
| `/admin/sessions` | 200 | ✅ | h1: Sessions | 0 | none |
| `/admin/scheduler` | 200 | ✅ | h1: Scheduler | 0 | none |
| `/admin/jobs/not-real` | 200 | ✅ | h1: Jobs (graceful) | 0 | none |

### Findings

- **11 of 11 routes return 200** — all JSON endpoints and LiveView admin pages functional.
- **`/admin/pack`** now renders gracefully when `ClusterDashboard` GenServer is not started
  in single-node dev mode. A safe fallback snapshot (`cluster_health: :down`, empty nodes,
  zero dispatches) is returned instead of a 500. Fixed in corrective commit.
- **`/admin/jobs/not-real`** gracefully returns 200 with the Jobs LiveView —
  no 404 or 500 for unknown job slugs. Correct LiveView behavior.
- **Zero console errors** on all routes.
- **Zero secret exposure** across all routes — no `sk-`, `api_key`, `token`,
  `BEGIN PRIVATE`, or `BEGIN CERTIFICATE` patterns found in any rendered HTML.
- **All LiveView admin pages** have `phx-attributes-present`, `data-phx-session`,
  and `data-phx-static` markers, confirming Phoenix LiveView websocket
  connection is active.

### Phoenix Log Review

After QA route hits, the Phoenix log contains **zero errors**. The `/admin/pack`
GenServer exit that was present in the initial QA run is now caught and handled
gracefully.

---

## 2. Dogfood / Runtime QA

### CLI Entry Points

| Command | Result |
|---------|--------|
| `uv run code-puppy --help` | ✅ Exit 0, shows `code-puppy 0.0.455` version and usage |
| `uv run pup --help` | ✅ Exit 0, same output as `code-puppy --help` |
| `uv run python -m code_puppy --help` | ✅ Exit 0, same output |

All three entry points resolve correctly and display the help text.

### Elixir Packaged Runtime

| Check | Command | Result |
|-------|---------|--------|
| Escript version | `./pup --version` | ✅ `code-puppy 0.1.0` |
| Escript help | `./pup --help` | ✅ Exit 0, usage displayed |
| Bridge-mode flag | `./pup --bridge-mode --help` | ✅ Parsed correctly, help displayed |
| Smoke test | `mix pup_ex.smoke` | ✅ SMOKE PASS — all 4 phases ok (198ms) |
| Packaged smoke | `./scripts/smoke-packaged.sh` | ✅ SMOKE PASS — all 5 phases ok (831ms) |
| Escript smoke | `mix pup_ex.smoke --escript` | ✅ SMOKE PASS — all 5 phases ok (805ms) |

### Plugin Loading

| Check | Result |
|-------|--------|
| `code_puppy.callbacks` import | ✅ Module imports cleanly |
| `register_callback` | ✅ Callable |
| `clear_callbacks` | ✅ Callable |
| `count_callbacks` | ✅ Callable (returns 0 at import time — expected, no full startup) |
| `get_callbacks` | ✅ Callable |
| `code_puppy.plugins` package | ✅ Importable |
| Plugin subdirectories | 35 directories (agent_memory, agent_shortcuts, elixir_bridge, etc.) |

Note: Full plugin discovery (registering `register_callbacks.py` and triggering hooks)
requires the full application runtime. Import-level checks confirm the module
structure is intact and the public API is available.

### Bridge Connectivity

The Elixir escript `--bridge-mode` flag is parsed and sets `PUP_RUNTIME=python`.
Full bridge smoke (Python ↔ Elixir JSON-RPC) is exercised by the smoke task's
one_shot phase, which dispatches to `MockLLM` and renders a canned reply.
No live model credentials required.

---

## 3. qa-kitten Blocker Note

qa-kitten could not execute due to model/tool configuration errors unrelated to
the Admin UI or Playwright availability. Playwright Chromium revision 1217 is
confirmed installed and functional (`/home/adam/.cache/ms-playwright/chromium-1217/`).
The automated Playwright QA above covers all routes qa-kitten would have tested.

---

## 4. Residual Risks

| ID | Risk | Severity | Recommendation |
|----|------|----------|----------------|
| RESIDUAL-K8-1 | ~~`/admin/pack` 500 in single-node dev~~ | ~~Medium~~ | **Fixed** — `safe_cluster_snapshot/0` catches `:exit` and returns fallback; `safe_cluster_subscribe/0` added. 11/11 routes now 200. |
| RESIDUAL-K8-2 | qa-kitten model/tool errors prevented browser-agent QA | Low | Investigate qa-kitten model config separately; Playwright coverage achieved via script |

---

## 5. Verdict

**K.8 QA: PASS** — 11/11 admin routes return 200 with LiveView active. The
`/admin/pack` 500 from the initial run has been fixed with a safe fallback
snapshot when `ClusterDashboard` is absent (single-node dev). All CLI entry
points, Elixir smoke tests, plugin imports, and bridge connectivity are
functional. Zero secret exposure. Zero console errors. No release blockers.

## 6. Corrective Action

The initial QA run found `/admin/pack` returning 500 when `ClusterDashboard`
GenServer was not started in single-node dev mode. This violated the K.8
acceptance criterion of no Admin UI 500s.

**Fix:** Added `safe_cluster_snapshot/0` and `safe_cluster_subscribe/0` helpers
in `PackLive` that catch `:exit` from the GenServer call and return a fallback
snapshot:

```elixir
@empty_cluster_snapshot %{
  nodes: %{},
  dispatch_history: [],
  totals: %{dispatches: 0, successes: 0, failures: 0},
  connected_nodes: 0,
  cluster_health: :down
}
```

**Tests added:** Two new tests in `pack_live_test.exs` under a
`"without ClusterDashboard (single-node dev)"` describe block that stops
the GenServer before the test and verifies `/admin/pack` renders with
HTTP 200, shows "down" cluster health, and handles tick events.

**Rerun result:** 11/11 routes return 200. 5/5 PackLive tests pass.
