# Git Hooks

This repo uses native Git hooks (no external dependencies).

## What runs

### pre-commit
- isort on staged `*.py` (black profile), restages fixes
- ruff format on staged `*.py`
- ruff check --fix on staged `*.py`

### pre-push
- Elixir compile (warnings-as-errors) on changed `.ex`/`.exs` files
- Elixir fast tests on changed `.ex`/`.exs` files
- Python ruff check on changed `.py` files
- Python smoke import on changed `code_puppy/**/*.py` files
- Test file review (advisory, non-blocking)

## Smart fallbacks

- If `isort` isn't available, we fall back to Ruff's import sorter: `ruff check --select I --fix`.
- All commands prefer `uv run` when present; otherwise run the binary directly.
- Hooks use NUL-delimited git output + Bash arrays for safe filename handling.

## Install hooks locally

```bash
# one-time install
./scripts/install-hooks.sh
```

The installer copies `scripts/git-hooks/{pre-commit,pre-push}` to `.git/hooks/`.

When beads is configured, `.beads/hooks/` chain hooks run beads integration first,
then delegate to `scripts/git-hooks/`.

## Files

- `scripts/git-hooks/pre-commit` — canonical pre-commit hook
- `scripts/git-hooks/pre-push` — canonical pre-push hook
- `scripts/install-hooks.sh` — one-time installer
- `.beads/hooks/` — beads integration chain hooks (delegates to `scripts/git-hooks/`)

## Notes

- Keep hooks fast and non-annoying.
- Prefer ruff + isort for Python. If you don't have `isort`, no problem — Ruff's I-rules will handle import ordering.
- CI should run the same checks on all files (not just staged).
