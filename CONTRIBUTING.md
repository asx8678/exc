# Contributing to Code Puppy

**Thank you for your interest in contributing!** This document outlines the guidelines for participating in this project.

## 🧊 Python Compatibility Freeze Policy

> **TL;DR**: The legacy Python product (`code_puppy/`, `pyproject.toml`,
> `uv.lock`, `.python-version`) has been **deleted**. The Elixir-native
> `pup` CLI and `CodePuppyControl` runtime are the only supported path.
> New plugin development targets Elixir `PluginBehaviour`.

### Rationale

Code Puppy now treats the Elixir `pup` CLI and `CodePuppyControl` runtime as the **only** supported runtime:
- The Elixir codebase (`elixir/code_puppy_control/`) is where **all runtime development happens**.
- **New plugin development must target the Elixir `PluginBehaviour` API** (see `docs/PLUGIN_MIGRATION.md`).
- The legacy Python product has been removed from the repository (see EPIC-C/E).
- `pup_ex` is a Mix task namespace; there is no separate `pup-ex` executable. Avoid new docs or UX that imply otherwise.
- **ADR-005 boundary**: BEAM-native Python source *parsing* (lexer/parser) remains as parser data support, not Python runtime support. Do not delete parser files.

### What's Allowed ✅

| Type | Examples |
|----------|----------|
|**_Elixir runtime development_** | New agents, plugins, tools, capabilities in `elixir/code_puppy_control/` |
|**_Documentation updates_** | README fixes, migration guides, API docs |
|**_Bug fixes_** | Crashes, data loss, security vulnerabilities in Elixir code |
|**_CI/infrastructure_** | Build, release, and CI pipeline improvements |

### What's NOT Allowed ❌

| Type | Examples |
|----------|-----------|
|**_Python runtime restoration_** | Re-adding `code_puppy/`, `pyproject.toml`, bridge mode, `PUP_RUNTIME=python` |
|**_Bridge-mode references_** | Docs or code that present Python bridge/PyPI as an active supported path |
|**_Non-Elixir runtime features_** | New Python agents, Python plugins, Python bridge endpoints |

### What Reviewers Should Enforce

1. **Check the file path** - New runtime code belongs in `elixir/code_puppy_control/`
2. **Require Elixir-first** - If a feature could go in Elixir, it must go in Elixir
3. **No stale references** - PRs should not re-introduce `PUP_RUNTIME`, `--bridge-mode`, `PythonWorker`, `PUP_PYTHON_WORKER_SCRIPT`, or `pyproject.toml` as active supported paths
4. **Preserve ADR-005 boundary** - Python *parsing* (lexer/parser) is BEAM-native; don't delete parser files
5. **Label appropriately** - Use `docs`, `feat`, or `fix` labels

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

All changes require review. The Python deletion policy (above) is enforced: no re-introduction of Python as a runtime path.

Note: reviewer enforcement only — no CI gate for Python restoration detection.

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
code-cuppy --agent qa-kitten --prompt "Analyze test coverage for: path/to/tests/"
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
- Run `bd prime` for detailed workflow reference and session close protocol
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
