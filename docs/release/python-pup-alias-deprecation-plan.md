# Python `pup` Alias Deprecation Plan

**Issue:** code-puppy-259
**Status:** Phase 1 shipped in codepp 0.0.456 (opt-in warning)
**Last Updated:** 2026-05-05

---

## Background

The Python/PyPI package `codepp` installs two console-script entry points:

| Entry Point | Canonical? | Since |
|---|---|---|
| `code-puppy` | **Yes** — canonical Python/PyPI command | Initial release |
| `pup` | **No** — legacy alias for backwards compatibility | Initial release |

The Elixir-native runtime also produces a `pup` escript and `code_puppy_control_*` Burrito binaries. The dual `pup` entry point creates PATH ambiguity: when both the Python `pup` and the Elixir `./pup` are on PATH, shell resolution order decides which runtime the user gets.

**Goal:** Deprecate and eventually remove the Python `pup` alias so that `pup` unambiguously means "Elixir-native CLI" and Python users reach the package through its canonical `code-puppy` command.

---

## Phase 1 — Opt-In Warning (Shipped in codepp 0.0.456)

**Trigger:** `PUP_PUP_ALIAS_DEPRECATED=1` environment variable set.
**Default:** Off (no warning unless user opts in).
**Shipped:** codepp 0.0.456 (2026-05-05)

### Behaviour

When the Python CLI is invoked via the `pup` entry point (detected by `sys.argv[0]` basename being `pup` or `pup.exe`) and `PUP_PUP_ALIAS_DEPRECATED` is set:

1. A user-facing warning is printed to **stderr** before any help/version/full runtime output.
2. A `DeprecationWarning` is emitted via `warnings.warn()`.
3. The CLI continues normally — no exit, no error.

When invoked as `code-puppy`, `code-puppy.exe`, or any other basename, no warning is emitted regardless of env var.

### Acceptance Criteria

- [x] Warning emitted on `PUP_PUP_ALIAS_DEPRECATED=1` when `sys.argv[0]` basename is `pup` or `pup.exe`
- [x] No warning when `sys.argv[0]` basename is `code-puppy` or `code-puppy.exe`
- [x] No warning when `PUP_PUP_ALIAS_DEPRECATED` is unset or empty
- [x] Warning fires before `--help` / `--version` / full runtime so that `pup --help` shows it
- [x] Tests cover all of the above

### Rollback / Suppression

- Unset `PUP_PUP_ALIAS_DEPRECATED` to suppress the warning.
- Remove the env var check in `cli_runner.py` to remove the feature entirely.

---

## Phase 2 — Default-On Warning (Future)

**Issue:** code-puppy-1xm
**Depends on:** Phase 1 bake-in period (≥1 Python release cycle, ≥2 weeks).
**Trigger:** Always on; no env var required.
**Suppress with:** `PUP_PUP_ALIAS_DEPRECATED=0` (explicit opt-out).

### Behaviour

When invoked via `pup` or `pup.exe`:

1. Stderr warning and `DeprecationWarning` are always emitted.
2. Setting `PUP_PUP_ALIAS_DEPRECATED=0` suppresses the warning for users who need time to migrate.

### Acceptance Criteria

- [ ] Warning emitted by default when `sys.argv[0]` basename is `pup` or `pup.exe`
- [ ] No warning when basename is `code-puppy` or `code-puppy.exe`
- [ ] `PUP_PUP_ALIAS_DEPRECATED=0` suppresses the warning
- [ ] Release notes and migration guide published
- [ ] Tests updated

### Rollback / Suppression

- Set `PUP_PUP_ALIAS_DEPRECATED=0` to suppress.
- Revert commit to restore opt-in-only behaviour.

---

## Phase 3 — Alias Removal (Future)

**Issue:** code-puppy-vp0
**Depends on:** Phase 2 bake-in period (≥2 Python release cycles, ≥4 weeks after Phase 2).
**Trigger:** The `pup = "code_puppy.main:main_entry"` entry point is removed from `pyproject.toml`.

### Behaviour

1. Remove `pup` from `[project.scripts]` in `pyproject.toml`.
2. Remove the deprecation warning code from `cli_runner.py`.
3. Remove the `PUP_PUP_ALIAS_DEPRECATED` env var handling.
4. Update all docs, tests, and help text to reference `code-puppy` only.

### Acceptance Criteria

- [ ] `pup` entry point removed from `pyproject.toml`
- [ ] `pip install codepp` no longer creates a `pup` command
- [ ] All docs reference `code-puppy` (Python) and `./pup` or native binary (Elixir)
- [ ] Deprecation warning code and env var handling removed
- [ ] Release notes with migration instructions
- [ ] Tests updated (deprecation tests removed or converted)

### Rollback

- Add `pup` entry point back to `pyproject.toml`.
- This is a breaking change; major or minor version bump required.

---

## Affected Artifacts

| Artifact | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| `pyproject.toml` `[project.scripts]` | Comment updated | Comment updated | `pup` entry removed |
| `code_puppy/cli_runner.py` | Warning added | Default-on logic | Warning code removed |
| `tests/test_cli_runner_deprecation.py` | Created | Updated | Removed |
| `README.md` | Pointer to this doc | Updated note | `pup` alias references removed |
| `FORK_CHANGELOG.md` | Pointer to this doc | Updated | Updated |
| `docs/release/python-free-runtime-guarantee-v0.1.x.md` | Follow-up F updated | Updated | Updated |
| Elixir `./pup` escript | **No change** | **No change** | **No change** |
| Elixir Burrito binaries | **No change** | **No change** | **No change** |
| Release overlay wrappers | **No change** | **No change** | Updated if referencing Python `pup` |

---

## CLI Name Resolution Guidance (Stable)

| Scenario | Recommended invocation |
|---|---|
| Python/PyPI (pip/uvx) | `code-puppy` or `uvx --from codepp code-puppy` |
| Elixir escript (local build) | `./pup` (explicit path) |
| Elixir Burrito binary | `code_puppy_control_<platform>` or symlinked `pup` |
| Bridge mode (Python worker) | `PUP_RUNTIME=python code-puppy` or `./pup --bridge-mode` |
| Avoid ambiguity | Never rely on bare `pup` when both runtimes are on PATH |
