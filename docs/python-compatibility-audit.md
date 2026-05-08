# Python Compatibility Audit — Stage A

> **Scope:** Classify all Python-related artifacts in the repository and document
> Stage A policy. Produced as part of `code-puppy-2xg` (root Elixir migration).
>
> **Last updated:** 2026-05-08
> **Status:** Stage A complete; Stage B deferred.

---

## Stage A Policy

1. **No Python deletion.** `code_puppy/`, `tests/`, `pyproject.toml`, `uv.lock`,
   `.python-version`, and Python packaging/compatibility tests remain at repo root.
2. **No Python relocation.** Moving Python into `legacy/python/` is a separate
   Stage B decision, deferred until Stage A is stable.
3. **Python/PyPI compatibility remains at root.** `pyproject.toml` + `uv.lock`
   continue to define the PyPI package from the repository root.
4. **Only stale path/reference cleanup.** Python files that referenced
   `elixir/code_puppy_control` were updated to use repo-root paths (Phase 8).
   No behavior refactors.

---

## Artifact Classification Table

| Path / Pattern | Type | Purpose | Classification | Stage A Decision |
|---|---|---|---|---|
| `code_puppy/` | Python package | Legacy CLI, runtime, PyPI compatibility, bridge transport | **required-runtime / legacy-compatibility** | Keep at root; no deletion |
| `code_puppy/elixir_transport.py` | Python runtime | Auto-detects Elixir project; routes stdio transport | **required-runtime** | Updated: repo root is first candidate, nested paths kept as transitional fallback |
| `code_puppy/plugins/elixir_bridge/` | Python runtime | Bridge-mode IPC (wire protocol, controller, callbacks) | **required-runtime** | No path change — communicates via stdio, no filesystem paths |
| `code_puppy/runtime_state.py` | Python runtime | Thin wrapper routing to Elixir RuntimeState GenServer | **required-runtime** | No change — uses transport singleton |
| `code_puppy/app_runner.py` | Python runtime | Entry-point orchestration; remediation hints | **required-runtime** | Updated: removed `cd elixir/code_puppy_control` from error hint |
| `code_puppy/command_line/core_commands.py` | Python runtime | CLI subcommand handlers; `start` → Phoenix hint | **required-runtime** | Updated: removed `cd elixir/code_puppy_control` from hint |
| `code_puppy/cli_runner.py` | Python runtime | `--bridge-mode` → `CODE_PUPPY_BRIDGE=1` entry point | **required-runtime** | No change — env-var based |
| `code_puppy/config/paths.py`, `config_paths.py` | Python runtime | XDG-compatible path resolution | **required-runtime** | No change — no Elixir app dir dependency |
| `tests/` | Python tests | Compatibility test suite (182 tests) | **required-test** | Keep at root; no deletion |
| `tests/test_bridge_*.py` | Python tests | Bridge controller, cancel, framing, mode | **required-test** | No change — mocks at boundary |
| `tests/test_runtime_state.py` | Python tests | RuntimeState wrapper, degraded-mode fallback | **required-test** | No change |
| `tests/test_bridge_mode.py` | Python tests | Subprocess lifecycle, `--bridge-mode` env propagation | **required-test** | No change |
| `tests/test_cli_runner_deprecation.py` | Python tests | Legacy `pup` alias deprecation warning | **required-test** | No change |
| `pyproject.toml` | Build/package | PyPI package config; `pup` console script alias | **required-packaging** | Keep; updated comment (nested `mix.exs` → root `mix.exs`) |
| `uv.lock` | Build/package | Python dependency lockfile | **required-packaging** | Keep |
| `.python-version` | Build/package | Python version pin (3.14) | **required-packaging / dev-env** | Keep |
| `benchmarks/` | Dev tooling | Python message-ops benchmarks | **optional-benchmark** | Keep; no change |
| `benchmarks/bench_message_ops.py` | Dev tooling | Elixir transport benchmark harness | **optional-benchmark** | No path change — uses transport API |
| `scripts/api_smoke.py` | Dev tooling | Retired FastAPI smoke tombstone | **required-dev-tooling** | Updated: removed `cd elixir/code_puppy_control` |
| `scripts/bench_baseline_harness.py` | Dev tooling | Benchmark baseline runner | **required-dev-tooling** | No change — no Elixir path refs |
| `scripts/bench_message_transport.py` | Dev tooling | Message transport benchmark | **required-dev-tooling** | No change |
| `scripts/depgraph_sanity_check.py` | Dev tooling | Dependency graph validation | **required-dev-tooling** | No change |
| `scripts/generate_python_dependency_graph.py` | Dev tooling | Dependency graph generator | **required-dev-tooling** | No change |
| `scripts/python-package-smoke.sh` | Dev tooling | PyPI artifact smoke test | **required-dev-tooling** | No change — `pup` alias stays |
| `src/python_lexer.xrl`, `src/python_lexer.erl` | Elixir source | Erlang/Leex lexer for Python syntax | **Elixir parser source (not Python runtime)** | Keep — Elixir-owned, no Python dependency |
| `src/python_parser.yrl`, `src/python_parser.erl` | Elixir source | Erlang/Yecc parser for Python syntax | **Elixir parser source (not Python runtime)** | Keep — Elixir-owned, no Python dependency |
| `test/code_puppy_control/parsing/parsers/python_parser_test.exs` | Elixir test | Parser correctness | **Elixir test (not Python runtime)** | Keep — Elixir-owned |
| `test/code_puppy_control/parsing/lexers/python_lexer_test.exs` | Elixir test | Lexer correctness | **Elixir test (not Python runtime)** | Keep — Elixir-owned |
| `test/code_puppy_control/python_free_runtime_test.exs` | Elixir test | Validates Python-free native runtime | **Elixir test (not Python runtime)** | Keep — Elixir-owned |
| `test/code_puppy_control/credentials/import_from_python_edge_cases_test.exs` | Elixir test | Credential import edge cases | **Elixir test (not Python runtime)** | Keep — Elixir-owned |
| `docs/PYTHON_PLUGIN_COMPATIBILITY.md` | Documentation | Plugin compatibility policy | **current-doc** | Keep; update stale paths if any |
| `docs/adr/ADR-004-python-to-elixir-migration-strategy.md` | Documentation | Migration ADR | **historical-doc-only** | Keep as-is (ADR is historical record) |
| `docs/adr/ADR-005-python-source-parsing-policy.md` | Documentation | Parsing policy ADR | **current-doc** | Keep; no path change needed |
| `docs/adr/ADR-002-python-elixir-event-protocol.md` | Documentation | Event protocol ADR | **current-doc** | Keep |
| `docs/architecture/python-singleton-audit.md` | Documentation | Singleton audit | **historical-doc-only** | Keep as-is |
| `docs/release/python-pup-alias-deprecation-plan.md` | Documentation | `pup` deprecation plan | **current-doc** | Keep |
| `docs/release/python-free-runtime-guarantee-v0.1.x.md` | Documentation | No-Python runtime guarantee | **current-doc** | Keep |
| `docs/python_dependency_graph.md` | Documentation | Dep graph narrative | **current-doc** | Keep |
| `docs/native-elixir-python-dependency-audit.md` | Documentation | Dependency audit | **historical-doc-only** | Keep as-is |

---

## Phase 8 Validation Summary

Stage A Python path-only edits were applied and validated:

| Check | Result |
|-------|--------|
| `uv sync --frozen` | ✅ 90 packages resolved |
| `ruff check code_puppy tests scripts` | ✅ All checks passed |
| `pytest tests -q` | ✅ 182 passed (14.4s) |
| `rg "elixir/code_puppy_control" code_puppy/ pyproject.toml` | ✅ Zero matches |

**Files edited in Phase 8:**

| File | Change |
|------|--------|
| `code_puppy/elixir_transport.py` | `_detect_project_path()`: repo root as first candidate |
| `code_puppy/app_runner.py` | Removed `cd elixir/code_puppy_control &&` from error hint |
| `code_puppy/command_line/core_commands.py` | Removed `cd elixir/code_puppy_control &&` from CLI hint |
| `pyproject.toml` | Comment: `mix.exs (repo root)` |

---

## Stage B — Deferred Future Isolation

After Stage A is stable, maintainers may optionally pursue:

- Move `code_puppy/`, `tests/`, `pyproject.toml`, `uv.lock`, `.python-version`
  into `legacy/python/` as a separate packaging migration.
- This is **not** part of Stage A and requires its own validation plan.

---

## Classification Key

| Value | Meaning |
|-------|---------|
| `required-runtime` | Python code needed for bridge/compat runtime to function |
| `required-packaging` | PyPI build/publish infrastructure |
| `required-test` | Python test suite protecting compatibility |
| `required-dev-tooling` | Scripts used in development/release workflows |
| `legacy-compatibility` | Code kept for backward compatibility, not active development |
| `optional-benchmark` | Performance benchmarks, not required for shipping |
| `historical-doc-only` | Documentation retained as historical record |
| `current-doc` | Documentation actively referenced |
| `Elixir parser source (not Python runtime)` | `.xrl`/`.yrl`/`.erl` files — Elixir/Erlang owned, no Python dependency |
| `Elixir test (not Python runtime)` | Elixir test files that reference Python concepts but are not Python |
