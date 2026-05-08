# State Migration: Python → Elixir Home

This document describes the one-shot state migration tool that copies
allowlisted files from the Python pup's home (`~/.code_puppy/`) to the
Elixir pup-ex home (`~/.code_puppy_ex/`), per the [ADR-003] escape hatch.

[ADR-003]: adr/ADR-003-dual-home-config-isolation.md

## Overview

Code Puppy is migrating from a Python runtime to an Elixir runtime
(see [ADR-004]). ADR-003 established **dual-home config isolation**:
the Elixir pup-ex gets its own home directory at `~/.code_puppy_ex/`
and must **never** write to the Python pup's home at `~/.code_puppy/`.

[ADR-004]: adr/ADR-004-python-to-elixir-migration-strategy.md

This migration tool bridges the gap: it copies your non-sensitive
settings from the Python home to the Elixir home so you don't have to
reconfigure everything from scratch.

**Key design principles:**

- **User-explicit only** — migration never runs automatically on startup
  or in the background. You opt in by running the command.
- **One-shot** — designed to be run once. Idempotent on re-run.
- **Copy-only** — your Python home is never modified or deleted.
- **Default-deny** — only explicitly allowlisted files are copied;
  everything else is refused.

## How to Run

### From the Python REPL (`pup`)

```bash
# Dry-run: see what WOULD be copied (no files are written)
/migrate

# Actually copy files
/migrate --confirm

# Overwrite existing files at destination
/migrate --confirm --force
```

### From the Elixir project (`pup_ex` Mix task)

```bash
# Dry-run
mix pup_ex.import

# Actually copy files
mix pup_ex.import --confirm

# Overwrite existing files
mix pup_ex.import --confirm --force
```

> **Note:** Both commands use the same ADR-003 allowlist. The Python-side
> tool is useful when the Elixir runtime is not yet installed. There is no
> `pup-ex` executable; `pup_ex` is the Mix task namespace, while the Elixir
> daily-driver CLI is built as `./pup` or packaged as `code_puppy_control_*`.

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `PUP_EX_HOME` | Override Elixir home destination | `~/.code_puppy_ex/` |
| `PUP_HOME` | Override Python home source (deprecated, takes precedence over `PUPPY_HOME`) | `~/.code_puppy/` |
| `PUPPY_HOME` | Override Python home source (legacy, used only when `PUP_HOME` is not set) | `~/.code_puppy/` |

> New variables use the `PUP_` prefix per project convention.
> `PUPPY_HOME` is deprecated but still supported. When both `PUP_HOME` and
> `PUPPY_HOME` are set, `PUP_HOME` takes precedence.

## What Gets Copied

### ✅ Allowed Imports

| Source Path | Destination Path | Notes |
|-------------|-----------------|-------|
| `extra_models.json` | `extra_models.json` | User-added model definitions |
| `models.json` | `models.json` | Model registry (deep-merged; existing values preserved) |
| `puppy.cfg` (`[ui]` section only) | `puppy.cfg` | Only cosmetic `[ui]` keys; secrets/paths filtered |
| `agents/*.json` | `agents/*.json` | Agent definition files |
| `skills/*/` | `skills/*/` | Skill directories (with `SKILL.md`) |

### ❌ Forbidden Imports (never copied)

| File / Directory | Reason |
|-----------------|--------|
| `oauth_*.json`, `*_token` | Cross-runtime auth is a security violation |
| `sessions/` | Runtime-specific state; sharing causes conflicts |
| `autosaves/` | Runtime-specific session data |
| `dbos_store.sqlite` | Binary format incompatible |
| `command_history.txt` | Runtime-specific history |
| Any file with `oauth`, `token`, or `_auth` in the name | Credential leakage risk |
| Any `.sqlite` / `.db` file | Binary format incompatible |
| Files not on the explicit allowlist | Default-deny policy |

## Security Properties

1. **Legacy home is never modified.** The migration tool only *reads*
   from `~/.code_puppy/` and *writes* to `~/.code_puppy_ex/`. Your Python
   pup continues to work exactly as before.

2. **Isolation guard enforced.** All writes go through
   `config_paths.safe_write()` and `config_paths.safe_mkdir_p()`, which
   raise `ConfigIsolationViolation` if any write targets the legacy home.

3. **Canonical path resolution.** Symlink attacks (e.g.,
   `~/.code_puppy_ex/data → ~/.code_puppy/data`) are caught because
   paths are resolved through `os.path.realpath` before guard checks.

4. **Dry-run by default.** Without `--confirm`, the tool reports what
   *would* be copied without writing any files.

## Rollback

If you want to revert to the Python pup after migrating:

```bash
# Just use the Python pup — it still works
pup

# The Elixir home is disposable; delete it to start fresh
rm -rf ~/.code_puppy_ex/
```

No data is lost because the migration only copies files. The Python
home remains intact throughout.

> **Important:** There is no automatic sync between the two homes.
> If you make changes in one runtime after migrating, those changes
> won't appear in the other unless you run the migration again.

## Troubleshooting

| Problem | Solution |
|---------|---------|
| "No legacy home to migrate from" | Ensure `~/.code_puppy/` exists and contains config files |
| "already exists; use --force" | Re-run with `--force` to overwrite, or delete the destination file |
| "forbidden by ADR-003 allowlist" | Expected for sensitive files; they are never copied |
| Permission denied on `~/.code_puppy_ex/` | Check directory permissions: `chmod 700 ~/.code_puppy_ex/` |

## Related Documentation

- [ADR-003: Dual-Home Config Isolation](adr/ADR-003-dual-home-config-isolation.md)
- [ADR-004: Python-to-Elixir Migration Strategy](adr/ADR-004-python-to-elixir-migration-strategy.md)
- [Elixir CLI quickstart](ELIXIR_CLI_QUICKSTART.md) — `mix pup_ex.doctor` health check and Elixir home setup
