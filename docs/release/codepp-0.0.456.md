# codepp 0.0.456 Release Notes

**Date:** 2026-05-05
**Distribution:** `codepp` on PyPI (Python/PyPI compatibility stream)
**Issue:** code-puppy-z3g

---

## Headline: Phase 1 `pup` Alias Deprecation — Opt-In Warning

This release ships **Phase 1** of the Python `pup` entry point deprecation
(plan: `docs/release/python-pup-alias-deprecation-plan.md`).

### What Changed

Setting `PUP_PUP_ALIAS_DEPRECATED=1` now produces an opt-in deprecation
warning when the CLI is invoked via the legacy `pup` entry point:

```console
$ PUP_PUP_ALIAS_DEPRECATED=1 pup --help
⚠  The 'pup' command is a legacy Python/PyPI alias for 'code-puppy'.
   It will be removed in a future release. Use 'code-puppy' instead.
   Suppress: unset PUP_PUP_ALIAS_DEPRECATED
   See: docs/release/python-pup-alias-deprecation-plan.md
```

- **Default behaviour unchanged**: no warning unless `PUP_PUP_ALIAS_DEPRECATED` is set.
- Warning fires before `--help`, `--version`, and full runtime so users always see it.
- A `DeprecationWarning` is also emitted via `warnings.warn()`.

### User Behaviour

| Invocation | `PUP_PUP_ALIAS_DEPRECATED` | Warning? |
|---|---|---|
| `code-puppy` | Any | **No** |
| `pup` | Unset or empty | **No** |
| `pup` | `1` | **Yes** (stderr + DeprecationWarning) |
| `pup.exe` (Windows) | `1` | **Yes** |

### Migration Guidance

| Runtime | Recommended invocation |
|---|---|
| Python/PyPI (pip/uvx) | `code-puppy` or `uvx --from codepp code-puppy` |
| Elixir escript (local build) | `./pup` (explicit path) |
| Elixir Burrito binary | `code_puppy_control_<platform>` or symlinked `pup` |
| Bridge mode (Python worker) | `PUP_RUNTIME=python code-puppy` or `./pup --bridge-mode` |
| Avoid PATH ambiguity | Never rely on bare `pup` when both runtimes are on PATH |

**The `pup` entry point is NOT removed in this release.** It remains
available for backwards compatibility. Phase 2 (default-on warning) and
Phase 3 (alias removal) will follow after appropriate bake-in periods.

---

## Validation Checklist

- [x] `uv lock --check` passes (lock consistent with `pyproject.toml`)
- [x] `git diff --check` clean (no whitespace errors)
- [x] `uv run pytest tests/test_cli_runner_deprecation.py -q` passes
- [x] `scripts/python-package-smoke.sh` — wheel name is `codepp-0.0.456`
- [x] `scripts/release-gate.sh --skip-elixir --python-dist` subset passes

---

## Publish & Tag Notes

**Python/PyPI stream only.** This does NOT change the Elixir-native version
or create an Elixir tag.

```bash
# Build
uv build --wheel

# Publish (requires PyPI credentials or Trusted Publisher)
uv publish
```

> **⚠️ Publish blocker:** PyPI credentials (`~/.pypirc`) and Trusted
> Publisher (GitHub OIDC) are not currently configured for this repository.
> Actual `uv publish` cannot be performed until one of the following is
> set up:
>
> 1. API token in `~/.pypirc` or `UV_PUBLISH_TOKEN` env var
> 2. GitHub Actions Trusted Publishing workflow (OIDC to PyPI)
>
> A follow-up issue tracks the external publishing step.

**Git tag (optional, Python stream):** `codepp/0.0.456`

---

## Files Changed

| File | Change |
|---|---|
| `pyproject.toml` | `version = "0.0.455"` → `"0.0.456"` |
| `uv.lock` | Updated consistently via `uv lock` |
| `docs/release/codepp-0.0.456.md` | This file (new) |
| `docs/release/python-pup-alias-deprecation-plan.md` | Phase 1 status → shipped in 0.0.456 |
| `docs/release/python-free-runtime-guarantee-v0.1.x.md` | Follow-up F → active since 0.0.456 |
| `FORK_CHANGELOG.md` | Release-history entry added |
