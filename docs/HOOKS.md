# Git Hooks

This repo uses native Git hooks (no external dependencies).

## What runs

### pre-commit
- Elixir format check (`mix format --check-formatted`) on staged `.ex`/`.exs` files

### pre-push
- Native-only guard (`.py` file introduction check)
- Elixir format check on changed `.ex`/`.exs` files
- Elixir compile (warnings-as-errors) on changed `.ex`/`.exs` files
- Test file review (advisory, non-blocking)

> **No tests are run in pre-push.** The hook is bounded and side-effect-free
> (code-puppy-c1r). Run `mix test` explicitly or rely on CI / `release-gate.sh`.
>
> Previously, pre-push ran `mix test --exclude slow/integration/property` which
> caused 60s+ timeouts and, due to cwd leakage in git_auto_commit tests,
> could create rogue commits in the real repo.

## Smart fallbacks

- Hooks use NUL-delimited git output + Bash arrays for safe filename handling.
- If `mix` is not available, Elixir checks are skipped with a warning.

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
- Never run `mix test` in hooks — tests can be slow and may have side effects (code-puppy-c1r).
- CI should run the same checks on all files (not just staged).
