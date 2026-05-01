# Contributing to Code Puppy

> **Note:** As of Phase H cutover, Code Puppy runs on **Elixir only**.
> The Python codebase has been removed. See ADR-004 for migration history.

**Thank you for your interest in contributing!** This document outlines the guidelines for participating in this project.

## General Development Guidelines

### Branch Naming
- `feature/description` for new features
- `fix/description` for bug fixes
- `docs/description` for documentation

### Commit Format

We use conventional commits:

```
type: Brief description

Longer explanation if needed.
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

Include the **bd issue ID** (e.g. `code_puppy-djs.7`) in the commit message body when the change addresses a tracked issue.

### Code Review

All changes require review.

### Automated Code Review for Test Files

All new and modified test files must pass automated review before merge. This ensures test quality, coverage, and idiomatic patterns.

#### Review Agents

| Language | Agent | Focus |
|----------|-------|-------|
| Elixir | `elixir-reviewer` | Anti-patterns, OTP idioms, supervision tree correctness |
| Any | `qa-expert` | Coverage gaps, assertion quality, test isolation, risk assessment |

> **Note:** Review agents use strong models for high-quality analysis.

#### Running Reviews Manually

```bash
# Review specific test files or directories
./scripts/review-tests.sh elixir/code_puppy_control/test/llm/

# Multiple paths
./scripts/review-tests.sh elixir/code_puppy_control/test/

# Treat findings as blocking (for CI gates)

# Or invoke agents directly for more control
code-puppy --agent elixir-reviewer --prompt "Review test file: path/to/test.exs"
code-puppy --agent qa-expert --prompt "Analyze test coverage for: path/to/tests/"
```

#### When Reviews Are Required

- **All new test files** must be reviewed by the appropriate language reviewer
- **Test suite changes** (adding/removing tests, modifying test infrastructure) require `qa-expert` coverage analysis
- **Pre-push hook** runs advisory review on `.exs` test files automatically

#### Current Status

Reviews are **advisory** — they won't block merge yet. Once the review agents are validated against the codebase, they'll be promoted to blocking gates.

To make reviews blocking in CI, set `REVIEW_BLOCKING=1` in the environment or add `--blocking` to the script invocation.

### Testing

- Add tests for bug fixes
- Ensure existing tests pass
- Run `mix test` in `elixir/code_puppy_control/`

### Questions?

> Reach out via:
> - **bd issues** for feature requests and bugs — see `bd ready` to find available work or `bd create` to file a new issue
> - Pack Leader agents for architectural questions

## Testing Tiers

During development, use tiered testing to minimize feedback time while maintaining quality.

### Test Commands by Context

| Context | Command | Scope |
|---------|---------|-------|
| Active development | `mix test.changed` | Changed files + their tests |
| Before commit | `mix test.changed --depth 2` | + dependent modules |
| Closing an issue | `mix test` | Full unit suite |
| Closing an epic | `mix test && mix test --only integration` | Everything |
| CI pipeline | Full suite | Always runs everything |

### Escalation Triggers

Always run the **full test suite** (`mix test`) when:

- **Config files changed:** `config/*.exs`, `mix.exs`
- **Test infrastructure changed:** `test/support/*`, `test_helper.exs`
- **Database migrations added/modified:** `priv/repo/migrations/*`
- **Many files changed:** 10+ files in a single change
- **Cross-cutting modules touched:** `application.ex`, `telemetry.ex`, `repo.ex`

### Quick Reference

```bash
# Development (fast)
mix test.changed              # Tests for uncommitted changes
mix test.changed --staged     # Tests for staged changes only
mix test.changed --base main  # Tests since branching from main

# Deeper analysis
mix test.changed --depth 2    # Include tests for dependent modules

# Full validation
mix test                      # All unit tests
mix test --only integration   # Integration tests
mix test --only e2e           # End-to-end tests
```

**Rule:** Agents default to `mix test.changed` during development. Full suite runs on issue/epic close.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
