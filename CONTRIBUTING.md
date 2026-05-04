# Contributing to Code Puppy

**Thank you for your interest in contributing!** This document outlines the guidelines for participating in this project.

## 🧊 Python Freeze Policy (during Elixir migration)

> **TL;DR**: The Python codebase is **FROZEN** during the Python→Elixir migration. 
> Only critical bug fixes, deprecation warnings, and docs updates are allowed.

### Rationale

Code Puppy is actively migrating from Python to Elixir (the `pup-ex` rewrite). During this transition:
- The Elixir codebase (`elixir/code_puppy_control/`) is where **new development happens** 
- The Python codebase (`code_puppy/`) is in **maintenance mode only** 
- Dual-maintenance would fragment effort and delay the migration

### What's Allowed ✅

| Type | Examples |
|----------|----------|
|**_Critical bug fixes_** | Crashes, data loss, security vulnerabilities |
|**_Deprecation warnings_** | Guiding users toward `pup-ex` equivalents |
|**_Documentation updates_** | README fixes, migration guides, API docs |
|**_CI/infrastructure_** | Changes that don't touch `code_puppy/**/*.py` |

### What's NOT Allowed ❌

| Type | Examples |
|----------|-----------|
|**_Refactors_** | Code reorganization, style changes, renaming |
|**_Schema changes_** | `puppy.cfg` modifications, `*.json` config changes |
|**_New features_** | New commands, tools, agents, or capabilities |
|**_Non-critical fixes_** | Typos, cosmetic bugs, edge cases with workarounds |

### What Reviewers Should Enforce

1. **Check the file path** - If it touches `code_puppy/**/*.py`, scrutinize heavily
2. **Require justification** - Every Python change needs an issue reference
3. **Label appropriately** - Use `bug-fix`, `docs`, or `deprecation` labels
4. **Ask: "Could this go in Elixir?"** - If yes, redirect the contributor

### Emergency Override Process

If a critical production fix is needed:
1. File an issue with label `critical-freeze-override`
2. Get approval from a maintainer
3. Merge with the appropriate conventional commit type (`fix` for bug fixes, `docs` for documentation)
4. Create a follow-up issue to port the fix to Elixir

### Timeline

This freeze remains in effect until the Elixir migration reaches parity. The freeze will be lifted incrementally as components are fully migrated.

---

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

All changes require review. The Python freeze policy (above) will be strictly enforced during the migration period.

Note: reviewer enforcement only — no CI gate.

### Automated Code Review for Test Files

All new and modified test files must pass automated review before merge. This ensures test quality, coverage, and idiomatic patterns.

#### Review Agents

| Language | Agent | Focus |
|----------|-------|-------|
| Elixir | `elixir-code-critic` | Anti-patterns, OTP idioms, Python-isms, supervision tree correctness |
| Web / browser QA | `qa-kitten` | Coverage gaps, assertion quality, test isolation, risk assessment |

> **Note:** Review agents use strong models (GPT-5.4, Claude Sonnet) for high-quality analysis.

#### Running Reviews Manually

```bash
# Review specific test files or directories
./scripts/review-tests.sh elixir/code_puppy_control/test/llm/

# Multiple paths
./scripts/review-tests.sh elixir/code_puppy_control/test/ tests/plugins/

# Treat findings as blocking (for CI gates)

# Or invoke agents directly for more control
code-puppy --agent elixir-code-critic --prompt "Review test file: path/to/test.exs"
code-puppy --agent qa-kitten --prompt "Analyze test coverage for: path/to/tests/"
```

#### When Reviews Are Required

- **All new test files** must be reviewed by the appropriate language reviewer
- **Test suite changes** (adding/removing tests, modifying test infrastructure) require `qa-kitten` coverage analysis
- **Pre-push hook** runs advisory review on `.exs` test files automatically
- **Local review** — run review scripts locally; CI comments are advisory for now

#### Current Status

Reviews are **advisory** — they won't block merge yet. Once the review agents are validated against the codebase, they'll be promoted to blocking gates.

To make reviews blocking in CI, set `REVIEW_BLOCKING=1` in the environment or add `--blocking` to the script invocation.

### Testing

- Add tests for bug fixes
- Ensure existing tests pass
- For Elixir code, run `mix test` in `elixir/code_puppy_control/`

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

## Phase H: Runtime Routing Infrastructure

Code Puppy now has a **dual-runtime routing layer** for the Python-to-Elixir migration:

### Feature Flags (`FeatureFlags`)

Per-capability toggles stored in `~/.code_puppy_ex/flags.json`:

```json
{
  "elixir.llm_client": false,
  "elixir.base_agent": false,
  "elixir.tools": false,
  "elixir.plugins": false,
  "elixir.cli": false
}
```

Elixir access:
```elixir
CodePuppyControl.FeatureFlags.enabled?("elixir.tools")  # O(1) ETS read
CodePuppyControl.FeatureFlags.set_flag("elixir.tools", true)  # persists to disk
```

### Runtime Selector (`RuntimeSelector`)

Determines which runtime handles a request based on `PUP_RUNTIME` env + feature flags:

| `PUP_RUNTIME` | Behavior |
|---------------|----------|
| `python` | Always delegate to Python bridge |
| `elixir` | Always handle in Elixir |
| `auto` (default) | Route per-capability via FeatureFlags |

```elixir
CodePuppyControl.RuntimeSelector.select("elixir.tools")  # => :elixir or :python
CodePuppyControl.RuntimeSelector.elixir_handles?("elixir.tools")  # => boolean
```

### Gradual Rollout (`Rollout`)

Percentage-based routing with error-rate observability:

```elixir
CodePuppyControl.Rollout.set_percentage("elixir.tools", 25)  # 25% of requests go to Elixir
CodePuppyControl.Rollout.record_outcome("elixir.tools", :elixir, :ok)  # track success
CodePuppyControl.Rollout.check_rollback("elixir.tools")  # => :ok or {:rollback, reason}
```

### Agent Guidelines for Phase H

- Check `RuntimeSelector.elixir_handles?(capability)` before processing a capability
- If it returns `false`, delegate to the Python bridge via `elixir_bridge`
- Record outcomes via `Rollout.record_outcome/3` for observability
- Never bypass the RuntimeSelector — it respects feature flags AND rollout percentages

---

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
