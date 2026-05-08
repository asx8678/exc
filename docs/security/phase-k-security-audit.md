# Phase K Security Audit

> **Date:** 2026-05-04
> **Scope:** Python dependency vulnerabilities, Elixir dependency audit, secrets exposure, file permissions, CI/supply-chain risks
> **Issue:** code-puppy-530.7
> **Status:** No high/critical blockers; 2 CVE fixes applied; low-risk residual items documented

---

## A. Python Dependency Vulnerabilities

### Method

```bash
uv export --format requirements-txt --no-hashes -o /tmp/codepp-req.txt
uv tool run pip-audit -r /tmp/codepp-req.txt
```

### Findings

| Package | Version | CVE | Fix Version | Status |
|---------|---------|-----|-------------|--------|
| `cryptography` | 46.0.6 | CVE-2026-39892 | 46.0.7 → 47.0.0 | **Fixed** — upgraded to 47.0.0 |
| `python-multipart` | 0.0.22 | CVE-2026-40347 | 0.0.26 → 0.0.27 | **Fixed** — upgraded to 0.0.27 |

### Verification

```bash
uv lock --upgrade-package cryptography --upgrade-package python-multipart
uv sync --frozen
uv export --format requirements-txt --no-hashes -o /tmp/codepp-req2.txt
uv tool run pip-audit -r /tmp/codepp-req2.txt
# → No known vulnerabilities found
```

Post-fix pip-audit: **0 vulnerabilities**.

The `codepp` package itself is skipped by pip-audit ("Dependency not found on PyPI") — expected, since it's the project package not yet published under that name.

### Python tests after upgrade

```bash
uv run ruff check code_puppy tests scripts  # → All checks passed!
uv run pytest tests/ -x -q                   # → 173 passed, 1 warning
```

---

## B. Elixir Dependencies

### Unused dependencies in lockfile

```bash
mix deps.unlock --check-unused
# Found: :expo, :floki, :gettext, :telemetry_metrics, :telemetry_poller, :toml
```

These were stale entries in `mix.lock` not declared in `mix.exs` (likely transitive
dependencies of previously-removed Phoenix HTML helpers or gettext). Cleaned:

```bash
mix deps.unlock --unused
# → Unlocked: expo, floki, gettext, telemetry_metrics, telemetry_poller, toml
```

Post-cleanup: `mix deps.unlock --check-unused` → **no unused deps**.

### Retired packages

```bash
mix hex.audit
# → No retired packages found
```

### Compile check

```bash
mix compile  # → Generated code_puppy_control app (warnings in .yrl parsers only)
```

All good. No Elixir dependency vulnerabilities or retired packages.

---

## C. Secrets and Sensitive Files

### Committed secrets scan

| Pattern | Files Found |
|---------|-------------|
| API key patterns (`sk-...`, `AIza...`) | **None** |
| Private key patterns (`BEGIN RSA`, `BEGIN PRIVATE`) | **None** |
| Hardcoded passwords/tokens | **None** |

### `.gitignore` coverage

| Path/Pattern | In `.gitignore`? |
|--------------|-------------------|
| `.env` | ✅ Yes (line 40) |
| `.code_puppy/` | ✅ Yes (line 9) |
| `.dolt/` | ✅ Yes (line 77) |
| `.beads-credential-key` | ✅ Yes (line 78) |

### `.env.example`

Contains only commented-out placeholder keys (e.g. `# OPENAI_API_KEY=sk-...`).
No real credentials. **No action needed.**

### Tracked credential-related source files

Files like `credentials.ex`, `crypto.ex` are **source code** implementing
AES-256-GCM encryption — they do not contain secrets themselves.
**No action needed.**

---

## D. File Permissions and Scripts

### Executable status

All release/CI scripts are executable (`-rwxr-xr-x`):

| Script | Executable | `set -e` |
|--------|------------|----------|
| `scripts/release-gate.sh` | ✅ | ✅ |
| `scripts/python-package-smoke.sh` | ✅ | ✅ |
| `scripts/review-tests.sh` | ✅ | ✅ |
| `scripts/codesign_macos.sh` | ✅ | ✅ |
| `scripts/install-git-hooks.sh` | ✅ | ✅ |
| `scripts/run_dev.sh` | ✅ | ✅ |
| `scripts/build-burrito.sh` | ✅ | ✅ |
| `scripts/smoke-packaged.sh` | ✅ | ✅ |
| `scripts/validate_mvp.sh` | ✅ | ✅ |

No scripts found without executable permission. All use `set -e` or `set -euo`.

### Shell safety scan

- No unsafe `eval $VAR` patterns found in shell scripts
- No unquoted variable expansions in critical paths
- No `sudo` usage in CI scripts
- No `/etc` writes

**No action needed.**

---

## E. Supply-Chain / CI Risks

### GitHub Actions version pinning

All actions use major-version tags (e.g. `@v4`, `@v5`, `@v1`), not pinned SHA digests.

| Risk | Severity | Notes |
|------|----------|-------|
| Tag-based action refs could be retagged by maintainers | **Low** | Standard practice; SHA pinning is defense-in-depth but not required for these well-known actions |

**Follow-up:** Consider SHA pinning for defense-in-depth (tracked as residual risk, not a release blocker).

### Secret handling

| Workflow | Secrets Used | PR Exposure |
|----------|-------------|-------------|
| `ci.yml` | **None** | N/A — no secrets in CI |
| `burrito-release.yml` | `WINDOWS_CODESIGN_CERT_BASE64`, `WINDOWS_CODESIGN_PASSWORD` | **Not exposed** — workflow only triggers on `v*` tag push and `workflow_dispatch`; release job gated by `startsWith(github.ref, 'refs/tags/v')` |

Signing secrets are **gracefully skipped** when absent:
```powershell
if (-not $env:CODESIGN_CERT_BASE64 -or -not $env:CODESIGN_PASSWORD) {
    Write-Host "Skipping Windows code signing: secrets not configured."
    exit 0
}
```

**No secret exposure risk.**

---

## Residual Risks and Follow-ups

| ID | Risk | Severity | Recommendation |
|----|------|----------|----------------|
| RESIDUAL-1 | GitHub Actions use tag refs not SHA digests | Low | Optional defense-in-depth; not a release blocker |
| RESIDUAL-2 | ~~Elixir format check fails on pre-existing unformatted files~~ | ~~Low~~ | **Fixed** — `mix format` applied to 33 files; `mix format --check-formatted` now passes. Pre-existing atom quoting and indentation normalization only; no logic changes |
| RESIDUAL-3 | `codepp` package not auditable by pip-audit (not on PyPI) | Informational | Expected; will be auditable after first PyPI publish |

**No follow-up issues filed** — all residual risks are low/informational and do not block release.

---

## Summary

- **2 CVEs fixed:** `cryptography` 46.0.6 → 47.0.0 (CVE-2026-39892), `python-multipart` 0.0.22 → 0.0.27 (CVE-2026-40347)
- **6 stale Elixir lock entries removed:** expo, floki, gettext, telemetry_metrics, telemetry_poller, toml
- **No committed secrets** found
- **All CI/release scripts** are executable, use `set -e`, and have no unsafe shell patterns
- **CI has zero secret exposure** on PRs; signing secrets are optional and gracefully skipped
- **No high/critical blockers** — K.7 can be closed
