# Native Elixir Python Dependency Audit

**Date:** 2026-05-05
**Issue:** `code-puppy-db8`
**Parent Epic:** `code-puppy-v2o` — Native Elixir pup cutover
**Auditor:** Max the Code Puppy (`code-puppy-68a5f1`)
**Status:** Complete

---

## 1. Executive Summary

The Burrito native binary is the primary daily-driver runtime. Under `PUP_RUNTIME=elixir` (or `auto`, which defaults to Elixir for all known capabilities), the native runtime operates with **zero Python dependency**. The Burrito smoke test (`smoke-burrito-native.sh`) explicitly sanitizes `PYTHONPATH`, `VIRTUAL_ENV`, `CONDA_PREFIX`, `PUP_PYTHON_WORKER_SCRIPT`, and `PYTHON_WORKER_SCRIPT` to prove this.

**Python remains in the repository for three purposes:**
1. **PyPI compatibility package** — the `codepp` PyPI distribution and its `code_puppy/` tree (legacy CLI, Python plugins/agents, bridge mode)
2. **Compatibility bridge** — `code_puppy/plugins/elixir_bridge/` (4,646 lines) enables Python-to-Elixir RPC when running in Python bridge mode (`PUP_RUNTIME=python` / `--bridge-mode`)
3. **Test/build tooling** — `pytest`, `ruff`, `pyproject.toml`, release-gate scripts

**Key finding:** The Python `runtime_selector.py` and `feature_flags.py` modules (planned in issues `code-puppy-bwt.2` and `code-puppy-djs.4.6`) were **never implemented**. Only the Elixir `RuntimeSelector` and `FeatureFlags` exist. This is actually *good* for the cutover — no stale Python-side routing code to remove.

**No blockers prevent deprecating Python as the default.** The remaining Python touchpoints fall into: compatibility-bridge-only, legacy-package-only, docs/install-references, and test/build-tooling. All are gated behind `PUP_RUNTIME=python` or `--bridge-mode`.

---

## 2. Proven Native Runtime Status

| Capability | Status | Evidence |
|------------|--------|---------|
| `file_ops` | ✅ Elixir-native | `CodePuppyControl.FileOps` |
| `repo_index` | ✅ Elixir-native | Elixir repo/index services |
| `parse` | ✅ Elixir-native | `CodePuppyControl.Parsing.Parser` |
| `agents/tools/sessions` | ✅ Elixir-native | Default runtime path |
| `PythonWorker.Port` | ✅ Gated | Only activated under `PUP_RUNTIME=python` |
| `PythonWorker.Supervisor` | ✅ Gated | DynamicSupervisor with graceful error when Python unavailable |
| Burrito native smoke | ✅ Passes | `smoke-burrito-native.sh` sanitizes all Python env vars |
| `PUP_PYTHON_WORKER_SCRIPT` | ✅ Optional | Config returns `nil` by default; required only for bridge mode |
| `PYTHON_WORKER_SCRIPT` | ✅ Deprecated | Legacy env var with deprecation warning |

**Conclusion:** The default runtime is already Elixir-first and Python-free. The audit confirms no hidden Python deps in the default path.

---

## 3. Methodology / Search Terms

Searched the entire repository (excluding `.git/`, `__pycache__/`, `node_modules/`) for:

| Search Term | Hits (unique files) | Primary Concern |
|-------------|--------------------|-----------------|
| `PythonWorker` | 15+ | Bridge-mode runtime dependency |
| `PUP_RUNTIME` | 25+ | Runtime selector config |
| `PUP_PYTHON_WORKER_SCRIPT` | 20+ | Bridge-mode config |
| `PYTHON_WORKER_SCRIPT` | 12+ | Deprecated legacy env var |
| `elixir_bridge` | 20+ | Python→Elixir RPC bridge |
| `fast_puppy` | 10+ | Historical acceleration stub |
| `native_backend` | 0 | No hits (removed) |
| `call_method` | 20+ | Bridge RPC call function |
| `pyproject.toml` | 25+ | Python packaging/test config |
| `PYTHONPATH` | 2 | Bridge test / smoke only |
| `VIRTUAL_ENV` | 1 | Smoke script only |
| `CONDA_PREFIX` | 1 | Smoke script only |
| `uvx` | 25+ | PyPI install method |
| `pipx` | 0 | No hits |
| `pytest` | 30+ | Python test tooling |
| `python3` | 20+ | Shebangs, MCP tools, bridge spawn |
| `--bridge-mode` | 0 | (searched via `bridge-mode`) |

---

## 4. Categorized Findings

### 4.1 Native-Safe / Already Elixir-Native

These are Elixir implementations with no runtime Python dependency. Python-side references are legacy/compat only.

| File / Module | Lines | Notes |
|---------------|-------|-------|
| `elixir/.../runtime_selector.ex` | 140 | Canonical runtime selector. `PUP_RUNTIME=auto` → `elixir`. No Python mirror exists. |
| `elixir/.../feature_flags.ex` | 308 | Canonical feature flags. Reads `flags.json`. No Python `feature_flags.py` exists. |
| `elixir/.../config.ex` | 611 | `PUP_PYTHON_WORKER_SCRIPT` conditional; returns `nil` for default runtime |
| `elixir/.../cli/smoke.ex` | ~460 | Explicitly unsets `PUP_PYTHON_WORKER_SCRIPT`, sanitizes PATH |
| `scripts/smoke-burrito-native.sh` | ~170 | Sanitizes PYTHONPATH, VIRTUAL_ENV, CONDA_PREFIX, PUP_PYTHON_WORKER_SCRIPT |
| `elixir/.../python_worker/port.ex` | 1,119 | **Gated**: `init/1` returns `{:stop, {:python_unavailable, _}}` when Python not found |
| `elixir/.../python_worker/supervisor.ex` | 134 | DynamicSupervisor; only spawns workers on demand in bridge mode |
| All Elixir plugins (`plugins/*.ex`) | — | No Python references; all ported natively |

### 4.2 Legacy Python Package Only

These exist only as part of the `codepp` PyPI distribution. They are **not** invoked by the Elixir native runtime.

| File / Module | Lines | Notes |
|---------------|-------|-------|
| `code_puppy/` (entire tree) | ~145K LOC | PyPI compat package; Python CLI, agents, plugins, tools |
| `pyproject.toml` | ~115 | Package metadata, ruff/pytest config |
| `.python-version` | 5 | Python version pin |
| `uv.lock` | ~192K | UV lockfile |
| `code_puppy/main.py` | — | Python CLI entry point |
| `code_puppy/cli_runner.py` | — | Python CLI runner |
| `code_puppy/interactive_loop.py` | — | Python interactive REPL |
| `code_puppy/app_runner.py` | — | Python app lifecycle (includes uvx detection, bridge mode) |
| `code_puppy/agents/*.py` | — | Python agent implementations (code_puppy, python_reviewer, etc.) |
| `code_puppy/tools/*.py` | — | Python tool implementations (command_runner, file_ops, etc.) |
| `code_puppy/mcp_/` | — | MCP client/server (Python) |
| `code_puppy/tui/` | — | Textual TUI (deprecated) |

### 4.3 Native Runtime Dependency / Blocker

**None found.** The native Elixir runtime does not import or call Python code at runtime under default `PUP_RUNTIME=auto|elixir` configuration.

The closest candidate was `PythonWorker.Port`, but it is fully gated: `init/1` returns a graceful error tuple when `python3` is not available, and the `Supervisor` does not start workers unless explicitly requested via bridge mode.

### 4.4 Compatibility Bridge Only

These enable Python→Elixir RPC when the Python CLI is running in bridge mode. They are dormant in the Elixir native runtime.

| File / Module | Lines | Category | Notes |
|---------------|-------|----------|-------|
| `code_puppy/plugins/elixir_bridge/__init__.py` | 783 | compat bridge | `call_method()`, `is_connected()`, async wrappers |
| `code_puppy/plugins/elixir_bridge/bridge_controller.py` | 1,735 | compat bridge | Bridge subprocess lifecycle, JSON-RPC over stdio |
| `code_puppy/plugins/elixir_bridge/wire_protocol.py` | 1,588 | compat bridge | Content-Length framing, serialization |
| `code_puppy/plugins/elixir_bridge/register_callbacks.py` | 540 | compat bridge | Bridge-mode startup/shutdown hooks |
| `code_puppy/elixir_transport.py` | 860 | compat bridge | Python→Elixir transport layer |
| `code_puppy/elixir_transport_helpers.py` | 263 | compat bridge | Transport helpers |
| `code_puppy/messaging/history_buffer.py` | 318 | compat bridge | Uses `call_method` for Elixir event store when connected |
| `code_puppy/model_factory.py` | 1,153 | compat bridge | Uses `call_method` for Elixir model providers when connected |
| `code_puppy/config/__init__.py` | 478 | compat bridge | Uses `call_method` for Elixir code_context when connected |
| `code_puppy/plugins/pack_parallelism/run_limiter.py` | 1,097 | compat bridge | Uses `call_method` for Elixir run limiter when connected |
| `code_puppy/plugins/pack_parallelism/register_callbacks.py` | 556 | compat bridge | Bridge-aware pack status checks |

**Subtotal: ~8,371 lines** of compatibility bridge code. All gated behind `is_connected()` checks that return `False` in native Elixir runtime.

### 4.5 Docs / Install References

| File | Category | Impact | Action |
|------|----------|--------|--------|
| `README.md` | docs/install | References `uvx --from codepp code-puppy` as install method | Update to prefer Burrito native binary first |
| `README.md` | docs/runtime | Documents `PUP_RUNTIME=python` as explicit bridge path | Keep (accurate) |
| `ARCHITECTURE.md` | docs/arch | Documents PythonWorker.Port bridge architecture | Keep (accurate for bridge mode) |
| `CONTRIBUTING.md` | docs/contrib | Documents Python compat freeze policy | Keep (accurate) |
| `AGENTS.md` | docs/agents | Documents bridge import pattern | Keep (accurate for compat) |
| `FORK_CHANGELOG.md` | docs/changelog | Historical reference | No action |
| `ROADMAP.md` | docs/roadmap | Completed migration phases | No action |
| `docs/ELIXIR_CLI_QUICKSTART.md` | docs/quickstart | Documents `PUP_RUNTIME`, `PUP_PYTHON_WORKER_SCRIPT` | Keep (accurate) |
| `docs/acceleration.md` | docs/accel | Documents Python-free runtime, env vars | Keep (accurate) |
| `docs/release/python-free-runtime-guarantee-v0.1.x.md` | docs/release | Proves Python-free guarantee | Keep (reference) |
| `docs/release/python-pup-alias-deprecation-plan.md` | docs/release | 3-phase deprecation plan for `pup` alias | Track progress |
| `docs/THIN_SHELL_CONTRACT.md` | docs/contract | References `fast_puppy/`, `turbo_indexer_bridge.py` | Historical; note as stale |
| `docs/adr/ADR-001-elixir-python-worker-protocol.md` | docs/adr | Worker protocol spec | Keep (reference) |
| `docs/adr/ADR-002-python-elixir-event-protocol.md` | docs/adr | Event protocol spec | Keep (reference) |
| `docs/adr/ADR-004-python-to-elixir-migration-strategy.md` | docs/adr | Migration strategy | Keep (reference) |
| `docs/triage/phase-h-reality-audit-2026-04-29.md` | docs/triage | Historical audit | No action |
| `docs/python_dependency_graph.json` | docs/deps | Generated dependency graph for Python tree | Historical; mark stale |

### 4.6 Test / Build Tooling Only

| File / Module | Lines | Category | Notes |
|---------------|-------|----------|-------|
| `pyproject.toml` `[tool.pytest]` | ~5 | test config | pytest/ruff configuration |
| `tests/` (Python) | — | test suite | Python unit/integration tests |
| `scripts/release-gate.sh` | ~200 | build tooling | Runs `uv run pytest`, `uv run ruff` as Python gates |
| `scripts/python-package-smoke.sh` | — | build tooling | Validates PyPI package |
| `benchmarks/` | — | test tooling | Python benchmarks |
| `elixir/.../python_worker_integration_test.exs` | ~350 | test | Integration tests for PythonWorker bridge |
| `elixir/.../python_free_runtime_test.exs` | — | test | Validates Python-free startup |
| `elixir/.../cli/smoke_test.exs` | — | test | Validates no_python PATH sanitization |
| `uvx_detection.py` | 244 | legacy pkg | Windows+uvx SIGINT workaround (Python CLI only) |

### 4.7 Dead / Stale Code Candidates

| File / Module | Lines | Category | Notes |
|---------------|-------|----------|-------|
| `code_puppy/plugins/fast_puppy/register_callbacks.py` | 23 | dead/stale | Stub that says "acceleration removed"; Elixir `fast_puppy.ex` is the canonical version |
| `code_puppy/runtime_selector.py` | N/A | **never created** | Planned in `code-puppy-bwt.2` but never implemented — Elixir-only |
| `code_puppy/feature_flags.py` | N/A | **never created** | Planned in `code-puppy-djs.4.6` but never implemented — Elixir-only |
| `docs/python_dependency_graph.json` | — | stale | Generated from Python tree; low value post-cutover |
| `docs/triage/phase-h-reality-audit-2026-04-29.md` | — | stale | Superseded by this audit and completed migration phases |
| `PYTHON_WORKER_SCRIPT` env var | — | deprecated | Legacy env var with deprecation warning; candidate for removal timeline |

---

## 5. Blockers vs. Non-Blockers

### Blockers for Full Python Deprecation/Deletion

| # | Blocker | Status | Issue |
|---|---------|--------|-------|
| 1 | Python plugins remain documented as the default plugin path in `CONTRIBUTING.md` and some docs | **Resolved** by `code-puppy-hb7` | Elixir-native plugins now documented as default |
| 2 | `codepp` PyPI package is the only install method for some users | **Open** | Burrito binary distribution needs parity |
| 3 | Python bridge mode (`PUP_RUNTIME=python`) is the only way to run Python-side agents/plugins | **By design** | Not a blocker for default cutover; bridge mode is opt-in |
| 4 | `pup` alias in `pyproject.toml` points to Python CLI | **Planned** | Deprecation plan exists: `docs/release/python-pup-alias-deprecation-plan.md` |

### Non-Blockers (Nice-to-Have)

| # | Item | Status |
|---|------|--------|
| 1 | `PUP_NO_PYTHON=1` convenience env var | `code-puppy-o4m` (P3, open). `PUP_RUNTIME=elixir` already provides this. Decision: implement or document-and-close. |
| 2 | Remove `PYTHON_WORKER_SCRIPT` legacy env var | Tracked in deprecation plan. Low priority. |
| 3 | Delete `fast_puppy` Python stub | Trivial cleanup; Elixir version is canonical. |
| 4 | Clean up stale triage docs | Housekeeping only. |

---

## 6. Recommended Follow-Up Issues

Grouped logically — **not** one per grep hit. These are the actionable outcomes.

### 6.1 Gate/Retire PythonWorker from Native Docs and Config (P2) — ✅ code-puppy-dh5

**Rationale:** The `PythonWorker.Port` and `PythonWorker.Supervisor` Elixir modules (1,253 lines) are only needed for bridge mode. Their presence in `runtime.exs`, `health_controller.ex`, and `bench.ex` should be conditional or clearly documented as "bridge-mode only."

**Actions:**
- Add `@moduledoc` annotation: "Only active when `PUP_RUNTIME=python`"
- Ensure `health_controller.ex` bridge health check is gated
- Validate bench task doesn't require Python worker in default runs

**Status:** Completed in code-puppy-dh5. All PythonWorker modules now carry bridge-mode-only `@moduledoc` annotations. Health controller, bench task, runtime snapshot, application.ex, stdio_service docs, and ELIXIR_STANDALONE_TRANSPORT.md all updated. No behavior changes — docs/comments/status-labeling only.

### 6.2 Decide `PUP_NO_PYTHON=1`: Implement or Document-and-Close (P3)

**Rationale:** Issue `code-puppy-o4m` is already open. `PUP_RUNTIME=elixir` already provides the no-Python guarantee. This is UX/ergonomics only.

**Actions:** Update `code-puppy-o4m` with this audit's finding: recommend **document-and-close** since `PUP_RUNTIME=elixir` is the canonical no-Python flag.

### 6.3 Port/Delete Stale `fast_puppy` Python Stub (P4)

**Rationale:** `code_puppy/plugins/fast_puppy/register_callbacks.py` (23 lines) is a dead stub. Elixir `fast_puppy.ex` is canonical.

**Actions:** Delete Python `fast_puppy` plugin dir. Verify no imports reference it.

### 6.4 Update README and Install Docs to Prefer Burrito Native (P2) — ✅ code-puppy-2j6

**Rationale:** `README.md` currently shows `uvx --from codepp code-puppy` prominently. The Burrito native binary should be the first-recommended install method.

**Actions:**
- Reorder README install section: Burrito first, escript as dev/smoke, Python/PyPI as "compatibility path"
- Add version stream distinction (0.1.x Elixir vs 0.0.x Python) more prominently
- Update `docs/acceleration.md`, `docs/getting_started.md`, and `docs/ELIXIR_CLI_QUICKSTART.md` similarly
- Make escript vs Burrito distinction explicit (escript = degraded, no Repo/Oban/Endpoint)

**Status:** Completed in code-puppy-2j6.

### 6.5 Define Native Plugin/Callback Migration Policy (P2)

**Rationale:** `CONTRIBUTING.md` and `AGENTS.md` document Python `register_callbacks.py` as the plugin interface. Elixir plugins are the default but the docs still present Python first.

**Actions:**
- Update docs to present Elixir plugin development as the primary path
- Document Python plugins as "compatibility bridge only" with a deprecation timeline
- Add example of Elixir plugin creation to `docs/PLUGIN_MIGRATION.md`

### 6.6 Add Native Agent/Tool/Model-Provider Parity Smoke (P3)

**Rationale:** While the audit found no hidden Python deps, there is no automated test that exercises the full native runtime workflow (agent → tool → model provider) and asserts zero Python imports. The existing `smoke-burrito-native.sh` covers CLI startup but not full workflow.

**Actions:**
- Add a mix test that runs a minimal agent→tool round-trip with `PUP_RUNTIME=elixir`
- Assert no `PythonWorker.Supervisor` children are started
- Gate in CI alongside existing Burrito smoke

---

## 7. Conclusion: What Must Change Before Python Can Be Fully Deprecated/Deleted

### Short-term (make Elixir-first official)

1. ✅ **Already done:** `PUP_RUNTIME=auto` defaults to Elixir; Burrito smoke passes Python-free
2. **Docs:** Reorder install/docs to prefer Burrito native binary (issue 6.4 above)
3. **Docs:** Present Elixir plugins as default, Python as compat bridge (issue 6.5 above)
4. **Decide:** Close `code-puppy-o4m` as `PUP_RUNTIME=elixir` is sufficient (issue 6.2 above)
5. **Docs:** Gate PythonWorker references in architecture docs as "bridge-mode only" — ✅ code-puppy-dh5

### Medium-term (Python becomes explicitly opt-in)

6. **PyPI deprecation:** Execute `python-pup-alias-deprecation-plan.md` phases 2–3
7. **Delete:** Remove `fast_puppy` Python stub (issue 6.3 above)
8. **Add:** Native workflow parity smoke test (issue 6.6 above)
9. **Gate:** PythonWorker.Supervisor only starts under explicit `PUP_RUNTIME=python`

### Long-term (Python tree removal)

10. **Delete:** `code_puppy/` tree, `pyproject.toml`, `uv.lock`, `.python-version`
11. **Delete:** `elixir_bridge/` Python bridge (4,646 lines)
12. **Simplify:** Remove `PUP_RUNTIME` env var complexity; Elixir is the only runtime
13. **Update:** `release-gate.sh` drops Python gate steps

**The native runtime is ready today.** The remaining work is documentation, UX, and housekeeping — not functionality.

---

*Audit completed 2026-05-05 by Max the Code Puppy. Issue: `code-puppy-db8`. Parent: `code-puppy-v2o`.*
