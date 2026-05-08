# Root Restructure — Beads Epic Plan

Derived from `ultimate_root_restructure_plan.md`. This document maps the
two-stage migration into Beads-tracked epics and child tasks.

> **Plan-only note:** old `elixir/code_puppy_control` paths below identify the migration source tree, not current post-migration developer instructions.

---

## Epic: Root Restructure — Elixir to Repository Root, Python Preserved

**Priority**: P1 · **Type**: epic

Two-stage migration:
- **Stage A (now):** Move Elixir-native app from `elixir/code_puppy_control/`
  to repository root. Preserve Python/PyPI compatibility at root unchanged.
- **Stage B (deferred/future):** Optionally isolate Python under `legacy/python/`.

---

## Stage A — Execute Root Elixir Migration (Python Preserved)

### Phase 0 — Capture Baseline
- Run `git status` / `git diff --stat`
- Record Elixir validation results (`mix deps.get`, compile, format, test) from old location
- Record Python validation results from root
- Commit baseline to `docs/root-restructure-validation.md`

### Phase 1 — Conflict and Inventory Audit
- Compare root vs `elixir/code_puppy_control` for overlapping files
- Check `README.md`, `priv/`, `scripts/`, `rel/`, `docs/` for conflicts
- Document what needs manual merge vs simple `git mv`

### Phase 2 — Core `git mv`
- Move `mix.exs`, `mix.lock` to root
- Move `config/`, `lib/`, `test/`, `src/`, `bench/` to root
- Move hidden config files (`.formatter.exs`, `.credo.exs`, etc.)
- Move `assets/` if present

### Phase 3 — Merge `priv/` Safely
- Diff `priv/models.json` root vs source
- Move unique files (plugins, repo, models_dev_api.json)
- Document decision for any merge conflicts

### Phase 4 — Merge `rel/` Safely
- Inspect and move release overlays
- Verify `mix.exs` release paths resolve from root

### Phase 5 — Merge Scripts / Fix Paths
- Move unique Elixir scripts to root `scripts/`
- Update script root-detection logic (cd paths, relative paths)

### Phase 6 — Merge Docs / README
- Move nested docs into root docs taxonomy
- Merge README content (keep root README canonical)
- Update CONTRIBUTING, ARCHITECTURE, AGENTS, ROADMAP

### Phase 7 — Wrapper Cleanup
- Remove empty `elixir/code_puppy_control/` and `elixir/` once empty
- Document any leftovers

### Phase 8 — Stale Path / Reference Updates
- CI/CD workflows (`.github/workflows/*.yml`)
- Python bridge path strings in `code_puppy/*.py`
- Elixir config/source/test references
- Documentation reference sweep

### Phase 9 — Python Compatibility Audit Doc
- Create `docs/python-compatibility-audit.md`
- Classify all Python artifacts in a decision table
- No Python deletion or relocation in Stage A

### Phase 10 — Validation and Release Smoke
- Full Elixir validation from root: compile, format, test, escript, release
- Full Python validation: uv sync, ruff, pytest, package smoke
- Release gate / Burrito validation (document any toolchain gaps)
- Stale path sweep confirming zero active old-path references

---

## Stage B — Optional Future Python Isolation (Deferred)

### B1 — Decision Gate
- Assess whether to move Python to `legacy/python/`
- Update CI, packaging, and developer docs accordingly
- Do NOT execute until Stage A is stable in CI

### B2 — Package / Workflow Relocation
- Move `code_puppy/`, `tests/`, `benchmarks/` under `legacy/python/`
- Move `pyproject.toml`, `uv.lock`, `.python-version`
- Update `.github/workflows/publish-pypi.yml` to run from `legacy/python/`

### B3 — Docs / Path Updates
- Update all docs referencing Python/PyPI paths
- Update bridge code locating repo root or `mix.exs`

### B4 — Validation
- Run full PyPI build/smoke validation from new location
- Run full Elixir validation from root (ensure nothing broke)
