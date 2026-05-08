# Ultimate Plan — Code Puppy Root Restructure + Python Compatibility Audit

## Executive Decision

Use a **two-stage migration**:

1. **Stage A — Execute now:** Move the Elixir-native app from `elixir/code_puppy_control/` to the repository root, preserve the existing Python/PyPI compatibility package at root, update all path references, and document every remaining Python usage.
2. **Stage B — Optional later:** After Stage A is stable, decide whether to move Python into `legacy/python/` as a separate packaging migration.

This is the strongest architecture because it avoids mixing two risky migrations. The Elixir app becomes root-native immediately, while Python compatibility remains unbroken.

---

## Best Parts Combined From the Submitted Plans

| Source plan | Best idea used in this ultimate plan |
|---|---|
| `gpt5.5.md` | Main architecture: Elixir root migration while preserving intentional Python compatibility. Strong audit/validation philosophy. |
| `deepseek.md` | Concrete conflict map, exact path-update checklist, concise validation commands, Python audit template. |
| `plan_kimi2.6.md` | Clean future architecture idea: optional `legacy/python/` isolation as a second-stage migration. |
| `owl.md` | Clear acceptance criteria, rollback approach, and conservative execution order. |
| `glmwafer51.md` | Detailed risk register, stale-reference detection, and root validation matrix. |
| `glm5.1-nahcrof.md` | Useful Elixir-only validation commands, but **not** its Python deletion strategy. |

---

## Non-Negotiable Architectural Rules

1. **Elixir becomes the canonical root app.** After migration, normal development commands must run from repository root: `mix deps.get`, `mix compile`, `mix test`, `mix escript.build`, release/Burrito commands.
2. **Python is not deleted in Stage A.** Keep `code_puppy/`, `tests/`, `pyproject.toml`, `uv.lock`, `.python-version`, and Python packaging/compatibility tests unless maintainers explicitly decide to kill PyPI compatibility.
3. **Use `git mv`, not copy/delete.** Preserve file history as much as possible.
4. **Do not overwrite conflicts blindly.** Especially `README.md`, `priv/`, `scripts/`, `docs/`, and `rel/`.
5. **Separate restructure from cleanup.** Only update Python paths needed for the move. Do not refactor Python code broadly.
6. **No active reference should still require `elixir/code_puppy_control`.** Historical references may remain only if explicitly marked historical.

---

## Target Structure After Stage A

```text
repo_root/
├── mix.exs                         # Elixir native app now at root
├── mix.lock
├── .formatter.exs
├── config/
├── lib/
├── test/                           # Elixir tests
├── priv/
│   ├── models.json
│   ├── models_dev_api.json         # if present in source
│   ├── plugins/
│   └── repo/
├── rel/                            # release overlays/config, if applicable
├── src/                            # lexer/parser sources, if used by Mix
├── bench/                          # Elixir benchmarks
├── scripts/                        # merged root + Elixir scripts
├── docs/                           # merged root + Elixir docs
├── README.md
├── CONTRIBUTING.md
├── ARCHITECTURE.md
├── AGENTS.md
├── ROADMAP.md
│
├── code_puppy/                     # retained Python compatibility package
├── tests/                          # retained Python tests
├── benchmarks/                     # retained Python benchmarks/tooling
├── pyproject.toml                  # retained Python/PyPI config
├── uv.lock                         # retained Python lockfile
├── .python-version                 # retained Python version pin
└── .github/workflows/
```

Important distinction:

```text
test/   = Elixir tests
tests/  = Python compatibility tests
lib/    = Elixir source
code_puppy/ = Python compatibility package
mix.exs = native/default Elixir app
pyproject.toml = legacy/PyPI compatibility package
```

---

# Stage A — Root Elixir Migration, Python Preserved

## Phase 0 — Create Branch and Capture Baseline

```bash
git status --short
git diff --stat
git checkout -b chore/restructure-elixir-root-python-audit
```

Baseline Elixir validation from the old location:

```bash
cd elixir/code_puppy_control
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
cd ../..
```

Baseline Python validation from repo root:

```bash
uv sync --frozen
uv run ruff check code_puppy tests scripts
uv run pytest tests
```

Record the results in a migration note, for example:

```text
docs/root-restructure-validation.md
```

---

## Phase 1 — Conflict and Inventory Audit

Before moving anything, inspect root and source app contents:

```bash
ls -la
ls -la elixir/code_puppy_control
find elixir/code_puppy_control -maxdepth 2 -type f | sort
find elixir/code_puppy_control -maxdepth 2 -type d | sort
```

Check for hidden or optional project files:

```bash
find elixir/code_puppy_control -maxdepth 1 -mindepth 1 -print | sort
```

Pay special attention to:

```text
.formatter.exs
.credo.exs
.dialyzer_ignore.exs
.env.example
.gitignore
Dockerfile
docker-compose.yml
assets/
rel/
priv/
scripts/
docs/
README.md
```

Conflict checks:

```bash
# README conflict: must merge manually, never overwrite.
test -f elixir/code_puppy_control/README.md && diff -u README.md elixir/code_puppy_control/README.md || true

# priv conflict: compare models/config files.
find priv elixir/code_puppy_control/priv -maxdepth 3 -type f | sort
[ -f priv/models.json ] && [ -f elixir/code_puppy_control/priv/models.json ] && \
  diff -u priv/models.json elixir/code_puppy_control/priv/models.json || true

# scripts conflict: verify no duplicate target names.
find scripts elixir/code_puppy_control/scripts -maxdepth 2 -type f | sort

# rel conflict: verify root rel and nested rel, if both exist.
find rel elixir/code_puppy_control/rel -maxdepth 3 -type f 2>/dev/null | sort
```

---

## Phase 2 — Move Non-Conflicting Elixir App Files With `git mv`

Move core files first:

```bash
git mv elixir/code_puppy_control/mix.exs ./mix.exs
git mv elixir/code_puppy_control/mix.lock ./mix.lock
```

Move hidden Elixir config if present:

```bash
[ -f elixir/code_puppy_control/.formatter.exs ] && git mv elixir/code_puppy_control/.formatter.exs ./.formatter.exs
[ -f elixir/code_puppy_control/.credo.exs ] && git mv elixir/code_puppy_control/.credo.exs ./.credo.exs
[ -f elixir/code_puppy_control/.dialyzer_ignore.exs ] && git mv elixir/code_puppy_control/.dialyzer_ignore.exs ./.dialyzer_ignore.exs
```

Move core directories:

```bash
git mv elixir/code_puppy_control/config ./config
git mv elixir/code_puppy_control/lib ./lib
git mv elixir/code_puppy_control/test ./test
git mv elixir/code_puppy_control/src ./src
git mv elixir/code_puppy_control/bench ./bench
```

If an `assets/` directory exists:

```bash
[ -d elixir/code_puppy_control/assets ] && git mv elixir/code_puppy_control/assets ./assets
```

---

## Phase 3 — Merge `priv/` Safely

Create root `priv/` if needed:

```bash
mkdir -p priv
```

Move unique Elixir `priv/` contents:

```bash
[ -f elixir/code_puppy_control/priv/models_dev_api.json ] && \
  git mv elixir/code_puppy_control/priv/models_dev_api.json priv/models_dev_api.json

[ -d elixir/code_puppy_control/priv/plugins ] && \
  git mv elixir/code_puppy_control/priv/plugins priv/plugins

[ -d elixir/code_puppy_control/priv/repo ] && \
  git mv elixir/code_puppy_control/priv/repo priv/repo
```

Handle `models.json` manually:

```bash
diff -u priv/models.json elixir/code_puppy_control/priv/models.json || true
```

Decision rule:

- If identical: keep root `priv/models.json`, remove/move nothing else.
- If root is stale and Elixir copy is canonical: replace root file intentionally.
- If both contain unique data: merge manually and document the decision.

After merge:

```bash
find priv -maxdepth 3 -type f | sort
```

---

## Phase 4 — Merge `rel/` Safely

Do not assume `rel/` is empty or identical. Inspect first:

```bash
find rel elixir/code_puppy_control/rel -maxdepth 4 -type f 2>/dev/null | sort
```

If nested `rel/` exists and root `rel/` does not:

```bash
git mv elixir/code_puppy_control/rel ./rel
```

If both exist, move only unique files and preserve root overlays:

```bash
# Example only; adjust after inspection.
mkdir -p rel/overlays
[ -f elixir/code_puppy_control/rel/overlays/vm.args.eex ] && \
  git mv elixir/code_puppy_control/rel/overlays/vm.args.eex rel/overlays/vm.args.eex
[ -f elixir/code_puppy_control/rel/overlays/ssl_dist.conf.eex ] && \
  git mv elixir/code_puppy_control/rel/overlays/ssl_dist.conf.eex rel/overlays/ssl_dist.conf.eex
```

Then verify `mix.exs` release paths now resolve from root.

---

## Phase 5 — Merge Elixir Scripts Into Root `scripts/`

Move only unique script names. Known likely Elixir scripts:

```bash
[ -f elixir/code_puppy_control/scripts/build-burrito.sh ] && \
  git mv elixir/code_puppy_control/scripts/build-burrito.sh scripts/build-burrito.sh

[ -f elixir/code_puppy_control/scripts/smoke-burrito-native.sh ] && \
  git mv elixir/code_puppy_control/scripts/smoke-burrito-native.sh scripts/smoke-burrito-native.sh

[ -f elixir/code_puppy_control/scripts/smoke-packaged.sh ] && \
  git mv elixir/code_puppy_control/scripts/smoke-packaged.sh scripts/smoke-packaged.sh

[ -f elixir/code_puppy_control/scripts/validate_mvp.sh ] && \
  git mv elixir/code_puppy_control/scripts/validate_mvp.sh scripts/validate_mvp.sh

[ -f elixir/code_puppy_control/scripts/sign-windows.ps1 ] && \
  git mv elixir/code_puppy_control/scripts/sign-windows.ps1 scripts/sign-windows.ps1
```

Then audit script root detection. Common fixes:

| Old assumption | New assumption |
|---|---|
| `cd elixir/code_puppy_control` | remove or `cd "$REPO_ROOT"` |
| `elixir/code_puppy_control/mix.exs` | `mix.exs` |
| `elixir/code_puppy_control/mix.lock` | `mix.lock` |
| `elixir/code_puppy_control/deps` | `deps` |
| `elixir/code_puppy_control/_build` | `_build` |
| `elixir/code_puppy_control/priv` | `priv` |
| `elixir/code_puppy_control/scripts` | `scripts` |

Specific script updates to check:

```text
scripts/release-gate.sh
scripts/review-tests.sh
scripts/api_smoke.py
scripts/validate_mvp.sh
scripts/build-burrito.sh
scripts/smoke-burrito-native.sh
scripts/smoke-packaged.sh
```

Important: if `validate_mvp.sh` previously used `cd "../.."` because it lived under `elixir/code_puppy_control/scripts/`, it likely needs to become `cd ".."` after moving to root `scripts/`.

---

## Phase 6 — Merge Elixir Docs and README

Move nested docs into the root docs taxonomy:

```bash
mkdir -p docs/release
[ -f elixir/code_puppy_control/docs/burrito-release.md ] && \
  git mv elixir/code_puppy_control/docs/burrito-release.md docs/release/burrito-release.md
```

Merge nested README manually:

```bash
diff -u README.md elixir/code_puppy_control/README.md || true
```

README rules:

- Keep root `README.md` canonical.
- Import useful Elixir setup/build/release instructions from nested README.
- Replace `cd elixir/code_puppy_control` with root commands.
- Explain the hybrid root clearly:
  - Elixir is the native/default app.
  - Python/PyPI is compatibility-only.
- Mention the `test/` vs `tests/` distinction.
- Mention `pup` CLI name collision/deprecation if already part of project docs.

---

## Phase 7 — Remove Empty Wrapper Directory Only After Inspection

```bash
find elixir/code_puppy_control -maxdepth 3 -print 2>/dev/null | sort
```

If the directory is empty:

```bash
rmdir elixir/code_puppy_control
rmdir elixir 2>/dev/null || true
```

If it is not empty, do not delete blindly. Document what remains and why.

---

## Phase 8 — Update All Path References

Run the main stale-path search:

```bash
rg -n --hidden --glob '!.git/**' 'elixir/code_puppy_control|cd elixir/code_puppy_control' .
```

### CI/CD updates

Update `.github/workflows/ci.yml`:

| Old | New |
|---|---|
| `working-directory: elixir/code_puppy_control` | remove or set root explicitly |
| `elixir/code_puppy_control/deps` | `deps` |
| `elixir/code_puppy_control/_build` | `_build` |
| `hashFiles('elixir/code_puppy_control/mix.lock')` | `hashFiles('mix.lock')` |
| `cd elixir/code_puppy_control` | remove |

Update `.github/workflows/burrito-release.yml`:

| Old | New |
|---|---|
| `working-directory: elixir/code_puppy_control` | remove |
| `elixir/code_puppy_control/deps` | `deps` |
| `elixir/code_puppy_control/_build` | `_build` |
| `hashFiles('elixir/code_puppy_control/mix.lock')` | `hashFiles('mix.lock')` |
| `elixir/code_puppy_control/burrito_out/*` | `burrito_out/*` |

For `.github/workflows/publish-pypi.yml`:

- In Stage A, do **not** move Python packaging, so most PyPI paths should remain root-based.
- Only update references that point to the old Elixir path, such as bridge checks or version comparisons.

### Scripts

Update:

```text
scripts/release-gate.sh
scripts/review-tests.sh
scripts/api_smoke.py
scripts/build-burrito.sh
scripts/smoke-burrito-native.sh
scripts/smoke-packaged.sh
scripts/validate_mvp.sh
scripts/python-package-smoke.sh, only if it references the old Elixir path
```

### Python compatibility code

Make only minimal path-string changes required by the restructure:

```text
code_puppy/app_runner.py
code_puppy/elixir_transport.py
code_puppy/command_line/core_commands.py
code_puppy/plugins/elixir_bridge/**, if present
```

Typical replacement:

```text
elixir/code_puppy_control  ->  . / repo root
```

Do not refactor Python behavior beyond path updates.

### Elixir config/source/tests

Search and update:

```bash
rg -n --hidden --glob '!.git/**' 'elixir/code_puppy_control|\.\./\.\./pyproject|rel/overlays|priv/|scripts/' mix.exs config lib test src rel scripts
```

Special checks:

- `mix.exs` aliases
- `elixirc_paths`
- escript config
- release config
- Burrito config
- `Application.app_dir(..., "priv/...")`
- test fixture paths
- parser/lexer paths under `src/`

### Documentation

Update active instructions in:

```text
README.md
CONTRIBUTING.md
ARCHITECTURE.md
AGENTS.md
CLAUDE.md
ROADMAP.md
FORK_CHANGELOG.md
docs/**/*.md
```

Root-level command examples should become:

```bash
mix deps.get
mix compile
mix test
mix escript.build
./pup --help
./scripts/release-gate.sh
```

---

## Phase 9 — Python Usage Audit Document

Create or update:

```text
docs/python-compatibility-audit.md
```

Use this table:

| Path/Reference | Type | Purpose | Decision |
|---|---|---|---|
| `code_puppy/` | Runtime/package | Legacy Python CLI/runtime and PyPI compatibility | Keep in Stage A |
| `tests/` | Test | Python compatibility tests | Keep in Stage A |
| `pyproject.toml` | Build/package | PyPI package config | Keep in Stage A |
| `uv.lock` | Build/package | Python dependency lock | Keep in Stage A |
| `.python-version` | Build/package | Python version pin | Keep in Stage A |
| `benchmarks/` | Dev tooling | Python performance/dev benchmarks | Keep or mark optional |
| `scripts/*.py` | Dev/release tooling | Smoke tests, depgraph, benchmarks | Audit individually |
| `docs/**python**` | Documentation | Migration/compatibility docs | Keep if accurate, update stale paths |
| `src/python_lexer.xrl`, `src/python_parser.yrl` | Elixir parser sources | Python language parsing, not Python runtime | Keep |
| `test/**/*python*` | Elixir tests | Python-free runtime/parser/bridge assertions | Keep if still relevant |

Classification values:

```text
required-runtime
required-packaging
required-test
required-dev-tooling
legacy-compatibility
optional-benchmark
historical-doc-only
obsolete-remove
future-isolate
```

Stage A decision:

```text
No Python deletion. No Python relocation. Only stale path/reference cleanup and documentation.
```

---

## Phase 10 — Final Validation From Repository Root

Elixir validation:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

Escript validation:

```bash
MIX_ENV=prod mix escript.build
./pup --help
```

Release/Burrito validation:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release
./scripts/build-burrito.sh
./scripts/smoke-burrito-native.sh
./scripts/smoke-packaged.sh
```

If Zig/Burrito/native toolchain is unavailable, record the limitation exactly instead of silently skipping.

Python compatibility validation:

```bash
uv sync --frozen
uv run ruff check code_puppy tests scripts
uv run pytest tests
./scripts/python-package-smoke.sh
```

Release gate:

```bash
./scripts/release-gate.sh
./scripts/release-gate.sh --skip-python
```

Phoenix/admin UI validation, if applicable:

```bash
mix phx.server
```

Manual checks:

- Admin dashboard loads.
- LiveView/WebSocket connections work.
- Health endpoint responds.
- CLI smoke command works.

Stale path sweep:

```bash
rg -n --hidden --glob '!.git/**' 'elixir/code_puppy_control|cd elixir/code_puppy_control' .
```

Expected result:

```text
Zero active stale references.
Historical references may remain only if clearly labeled historical.
```

---

## Recommended Commit Series

Use small commits so rollback is easy:

```text
1. docs: record root restructure baseline and python audit plan
2. chore: move elixir app to repository root
3. chore: merge elixir priv scripts docs and release files
4. chore: update paths after root restructure
5. docs: document retained python compatibility layer
6. test: record root validation results
```

If Python files are touched, commit message should explicitly state that changes are path-only and required by the root migration.

---

## Risk Register

| Risk | Impact | Mitigation |
|---|---:|---|
| CI still uses old `working-directory` | High | Update all workflows; run stale-path sweep. |
| CI cache keys still point to old paths | Medium | Update `deps`, `_build`, and `mix.lock` cache paths. |
| `priv/` merge loses config | High | Diff `models.json`; move only unique files; document canonical choice. |
| `rel/` merge breaks release | High | Inspect root and nested `rel/`; validate `mix release` and Burrito. |
| Script root detection breaks | High | Audit all moved scripts; validate release gate and smoke scripts. |
| Python bridge still launches old path | High | Update minimal path strings in `code_puppy/*`; run Python smoke tests. |
| Documentation remains stale | Medium | Update README/docs in same PR; run `rg` sweep. |
| Git history becomes hard to follow | Low | Use `git mv` only. |
| Python freeze policy violated | Medium | Do not refactor Python; only path updates and documentation. |
| Moving Python too early breaks PyPI | High | Defer `legacy/python/` to Stage B. |

---

## Rollback Plan

If changes are uncommitted:

```bash
git restore .
git clean -fd
```

If changes are committed as one commit:

```bash
git revert HEAD
```

If changes are committed as multiple commits:

```bash
git log --oneline -10
git revert <latest-commit-sha>
git revert <previous-commit-sha>
```

After rollback, validate original layout:

```bash
cd elixir/code_puppy_control
mix deps.get
mix compile
mix test
cd ../..
uv sync --frozen
uv run pytest tests
```

---

## Stage A Acceptance Criteria

### Structure

- [ ] `mix.exs` and `mix.lock` are at repository root.
- [ ] `config/`, `lib/`, `test/`, `priv/`, `src/`, and `bench/` are at repository root.
- [ ] Developers no longer need `cd elixir/code_puppy_control`.
- [ ] `elixir/code_puppy_control/` is removed or contains only documented leftovers.
- [ ] Root `test/` and Python `tests/` coexist intentionally.

### Elixir

- [ ] `mix deps.get` works from root.
- [ ] `mix compile --warnings-as-errors` passes from root.
- [ ] `mix format --check-formatted` passes from root.
- [ ] `mix test` passes from root.
- [ ] `mix escript.build` works from root.
- [ ] `./pup --help` works.
- [ ] Release/Burrito paths work or toolchain limitation is documented.

### Python

- [ ] `code_puppy/`, `tests/`, `pyproject.toml`, `uv.lock`, and `.python-version` remain intact.
- [ ] `uv sync --frozen` works.
- [ ] `uv run ruff check code_puppy tests scripts` passes.
- [ ] `uv run pytest tests` passes.
- [ ] Python package smoke test passes.
- [ ] Python audit document classifies all remaining Python usage.

### CI/CD

- [ ] Elixir jobs run from repository root.
- [ ] Elixir cache paths use `deps`, `_build`, and `mix.lock`.
- [ ] Burrito artifact path is `burrito_out/*`.
- [ ] PyPI workflow remains valid for root Python package.
- [ ] No active workflow references `elixir/code_puppy_control`.

### Documentation

- [ ] README uses root-level Elixir commands.
- [ ] CONTRIBUTING explains Elixir default and Python compatibility freeze.
- [ ] ARCHITECTURE reflects the hybrid root layout.
- [ ] Docs no longer instruct users to `cd elixir/code_puppy_control`.
- [ ] Any historical old-path references are clearly labeled historical.

---

# Stage B — Optional Future Python Isolation

Only consider this after Stage A passes locally and in CI.

## When Stage B Makes Sense

Move Python to `legacy/python/` only if maintainers want a cleaner root and are willing to update PyPI workflows, developer docs, and packaging assumptions.

## Target Structure for Stage B

```text
repo_root/
├── mix.exs
├── mix.lock
├── config/
├── lib/
├── test/
├── priv/
├── scripts/
├── docs/
└── legacy/
    └── python/
        ├── code_puppy/
        ├── tests/
        ├── benchmarks/
        ├── pyproject.toml
        ├── uv.lock
        ├── .python-version
        └── scripts/
```

## Stage B Requirements

- Update `.github/workflows/publish-pypi.yml` to run from `legacy/python/`.
- Update Python lint/test commands:

```bash
cd legacy/python
uv sync --frozen
uv run ruff check code_puppy tests scripts
uv run pytest tests
```

- Update package smoke scripts.
- Update all docs that mention Python/PyPI paths.
- Update any bridge code that locates repo root or `mix.exs`.
- Run full PyPI build/smoke validation before merging.

## Stage B Decision Rule

Do **not** execute Stage B in the same PR as Stage A unless the team has explicitly decided that breaking/rewiring Python packaging is acceptable. Stage B is cleaner architecturally, but Stage A is safer and should happen first.

---

## Final Recommendation

The best ultimate plan is:

```text
Stage A now:
  Move Elixir app to root.
  Preserve Python compatibility at root.
  Update every old path.
  Validate Elixir, release, CI, and Python compatibility.
  Document Python usage.

Stage B later:
  Optionally move Python into legacy/python/ after Stage A is stable.
```

This gives the repository the safest immediate migration and the cleanest long-term direction.
