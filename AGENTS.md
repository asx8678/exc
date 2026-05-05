# Contributing to Code Puppy

> **Golden rule:** nearly all new functionality should be a **plugin**. Prefer
> Elixir plugins under `elixir/code_puppy_control/lib/code_puppy_control/plugins/`
> for the default runtime; use `code_puppy/plugins/` only for legacy Python/PyPI
> compatibility. Don't edit `code_puppy/command_line/` unless you're deliberately
> touching the legacy Python CLI.

## How Plugins Work

### Elixir Plugins (Recommended / Default Runtime)

For the native `pup` runtime (Burrito binary or escript), write Elixir plugins
implementing `PluginBehaviour`:

**Builtin** — `priv/plugins/my_feature/register_callbacks.ex`:

```elixir
defmodule MyFeature do
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature"

  @impl true
  def register do
    Callbacks.register(:startup, fn ->
      IO.puts("my_feature loaded!")
    end)
    :ok
  end
end
```

**User** — `~/.code_puppy_ex/plugins/my_feature/register_callbacks.ex`:

Same module structure; place under the user plugins directory. The Elixir loader
auto-discovers `register_callbacks.ex` (preferred, compiles to BEAM) and
`register_callbacks.exs` (fallback, evaluated at runtime).

> **Security note:** user plugins in `~/.code_puppy_ex/plugins/` execute arbitrary
> Elixir code with full system privileges — same trust model as Python plugins.
> Only load plugins from sources you trust. See
[docs/PYTHON_PLUGIN_COMPATIBILITY.md](docs/PYTHON_PLUGIN_COMPATIBILITY.md) for full details.
### Python Plugins (Compatibility / Bridge Mode Only)

Python `register_callbacks.py` plugins are supported for the legacy PyPI
compatibility package and explicit bridge mode (`PUP_RUNTIME=python` / `--bridge-mode`):

```python
# code_puppy/plugins/my_feature/register_callbacks.py (builtin)
# ~/.code_puppy/plugins/my_feature/register_callbacks.py (user)
from code_puppy.callbacks import register_callback

def _on_startup():
    print("my_feature loaded!")

register_callback("startup", _on_startup)
```

> **⚠️ Python plugins are compatibility-only.** New plugin development should
> target the Elixir `PluginBehaviour` API. The Python freeze policy (see
> CONTRIBUTING.md) restricts changes to `code_puppy/**/*.py`.
>
> **Security note:** user plugins in `~/.code_puppy/plugins/` are treated as trusted
> local Python code. They are imported and executed during plugin discovery with
> the same local privileges as Code Puppy itself. There is currently no isolated
> safe mode for user plugins, so do not install untrusted plugins.

Full plugin development guide: [docs/PLUGIN_MIGRATION.md](docs/PLUGIN_MIGRATION.md).

## Runtime Integration & Python Bridge

Code Puppy's default runtime is now **Elixir-native** (`CodePuppyControl`). The old native-acceleration/profile layer is gone; do not add replacement backend facades or profile-switching shims.

| Capability | Current owner | Notes |
|------------|---------------|-------|
| `file_ops` | `CodePuppyControl.FileOps` | Batch file ops (`list_files`, `grep`, `read_file`) |
| `repo_index` | Elixir repo/index services | Repository indexing |
| `parse` | `CodePuppyControl.Parsing.Parser` | Elixir-only parse operations (elixir, erlang, python, javascript, typescript, tsx, rust) |
| agents/tools/sessions | Elixir runtime | Default daily-driver path |
| Python plugins/agents | Python bridge | Explicit compatibility path only |

Python bridge access pattern:
```python
from code_puppy.plugins.elixir_bridge import is_connected, call_method

if is_connected():
    result = call_method('code_context.explore_file', {'file_path': path})
else:
    result = {'error': 'Elixir bridge is not connected'}
```

**Agent Guidelines:**
- Check bridge availability via `code_puppy.plugins.elixir_bridge.is_connected()` before Python compatibility code calls Elixir.
- Parse operations are Elixir-owned. Do not add a Python runtime parse backend; narrowly scoped UI heuristics are okay only when clearly documented as compatibility behavior.
- Import from `code_puppy.plugins.elixir_bridge` instead of direct bridge internals.
- Default runtime work belongs in Elixir (`CodePuppyControl`). Use Python only for legacy/PyPI compatibility, Python plugins/agents, or explicit bridge mode (`PUP_RUNTIME=python`, `--bridge-mode`).
- `PUP_PYTHON_WORKER_SCRIPT` is required only when explicit Python bridge mode is selected and a worker script cannot otherwise be configured.

## Available Hooks

Elixir: `Callbacks.register(:hook_name, fn)` — see `CodePuppyControl.Callbacks.Hooks` for authoritative arities.
Python: `register_callback("hook_name", func)` — deduplicated, async hooks accept sync or async functions.

| Hook | When | Signature |
|------|------|-----------|
| `startup` | App boot | `() -> None` |
| `shutdown` | Graceful exit | `() -> None` |
| `invoke_agent` | Sub-agent invoked | `(*args, **kwargs) -> None` |
| `agent_exception` | Unhandled agent error | `(exception, *args, **kwargs) -> None` |
| `agent_run_start` | Before agent task | `(agent_name, model_name, session_id=None) -> None` |
| `agent_run_end` | After agent run | `(agent_name, model_name, session_id=None, success=True, error=None, response_text=None, metadata=None) -> None` |
| `load_prompt` | System prompt assembly | `() -> str \| None` |
| `run_shell_command` | Before shell exec | `(context, command, cwd=None, timeout=60) -> dict \| None` (return `{"blocked": True}` to block) |
| `file_permission` | Before file op | `(context, file_path, operation, ...) -> bool` |
| `pre_tool_call` | Before tool executes | `(tool_name, tool_args, context=None) -> Any` |
| `post_tool_call` | After tool finishes | `(tool_name, tool_args, result, duration_ms, context=None) -> Any` |
| `custom_command` | Unknown `/slash` cmd | `(command, name) -> True \| str \| None` |
| `custom_command_help` | `/help` menu | `() -> list[tuple[str, str]]` |
| `register_tools` | Tool registration | `() -> list[dict]` with `{"name": str, "register_func": callable}` |
| `register_agents` | Agent catalogue | `() -> list[dict]` with `{"name": str, "class": type}` |
| `register_model_type` | Custom model type | `() -> list[dict]` with `{"type": str, "handler": callable}` |
| `load_model_config` | Patch model config | `(*args, **kwargs) -> Any` |
| `load_models_config` | Inject models | `() -> dict` |
| `get_model_system_prompt` | Per-model prompt | `(model_name, default_prompt, user_prompt) -> dict \| None` |
| `stream_event` | Response streaming | `(event_type, event_data, agent_session_id=None) -> None` |
| `get_motd` | Banner | `() -> tuple[str, str] \| None` |

Full list + rarely-used hooks: see `code_puppy/callbacks.py` (Python) or
`CodePuppyControl.Callbacks.Hooks` (Elixir — authoritative source).

**Elixir-only hooks** (no Python equivalent): `:version_check`, `:agent_reload`,
`:edit_file`, `:create_file`, `:replace_in_file`, `:delete_snippet`,
`:delete_file`, `:register_mcp_catalog_servers`, `:register_browser_types`,
`:register_model_providers`, `:message_history_processor_start`,
`:message_history_processor_end`.

See [docs/PLUGIN_HOOK_REFERENCE.md](docs/PLUGIN_HOOK_REFERENCE.md) for the complete
Elixir hook reference with arities and merge strategies.

## Prompt Assembly Architecture

The system prompt is built in layers by different components. Understanding this helps explain where customizations apply:

| Layer | Component | What It Does | Current Status |
|-------|-----------|--------------|----------------|
| 1 | `get_system_prompt()` | Agent-specific base prompt (e.g., code-puppy instructions) | **Stable** - Every agent implements this |
| 2 | `AgentPromptMixin.get_full_system_prompt()` | Adds platform info (OS, shell, cwd) + agent identity | **Stable** - Called by agents that need full context |
| 3 | `callbacks.on_load_prompt()` | Plugin additions (e.g., file mentions, pack-parallelism limits) | **Opt-in per agent** - Not all agents call this! |
| 4 | `prepare_prompt_for_model()` | Model-specific adaptation (claude-code) | **Stable** - Automatic based on model name |
| 5 | `callbacks.on_get_model_system_prompt()` | Model-type plugins can override final output | **Extension point** - For custom model types |

### Known Inconsistencies (Unresolved)

- **UNK3**: Whether `load_prompt` should apply globally to ALL agents is **unresolved**. Currently some agents call it, others don't.
- **Merge semantics**: String returns from `load_prompt` are concatenated; dict returns from `get_model_system_prompt` are chained. This asymmetry is intentional but confusing.

## Rules

1. **Plugins over core** — if a hook exists for it, use it
2. **Prefer Elixir plugins** — Elixir `PluginBehaviour` is the default extension mechanism for the native runtime
3. **One `register_callbacks` file per plugin** — `.ex`/`.exs` (Elixir) or `.py` (Python compat) at module scope
4. **600-line hard cap** — split into submodules
5. **Fail gracefully** — never crash the app
6. **Return `None` / `nil` from commands you don't own**

## Audit-Driven Development Rules

The following rules are enforced based on project audit findings:

### Async I/O in Async Callbacks

All async callback implementations **must use non-blocking I/O only**:

```python
# CORRECT: async context manager with proper I/O
async def _on_shutdown_async():
    await asyncio.gather(*pending_tasks)  # Non-blocking

# INCORRECT: blocking I/O in async callback
async def _on_shutdown_bad():
    time.sleep(5)  # Blocking! Use asyncio.sleep instead
```

**Rule**: If your callback is registered as async, **all I/O must be async-native**. Use `asyncio` primitives, not blocking stdlib calls.

### Environment Variable Naming Convention

Environment variables follow strict prefixes for namespacing:

| Prefix | Purpose | Example |
|--------|---------|---------|
| `PUP_` | Core runtime settings | `PUP_DEBUG=1` |
| `PUPPY_` | Legacy compatibility | `PUPPY_HOME` |
| `CODEPUP_` | CI/build environment | `CODEPUP_CI=1` |

**Rule**: New variables **must use `PUP_` prefix**. Legacy `PUPPY_` is supported but deprecated.

### Hook Merge Semantics

When multiple callbacks register for the same hook, results are **merged by type**:

| Hook Return Type | Merge Strategy |
|-----------------|---------------|
| `str` | Concatenation (newlines) |
| `list` | Extend (concatenate) |
| `dict` | Update (later wins on conflict) |
| `bool` | OR (any True wins) |
| `None` | Ignored |

```python
# Example: load_prompt returns are concatenated
def my_prompt():
    return "\n\n## Custom Instructions"  # Appended to base prompt

register_callback("load_prompt", my_prompt)
```

**Rule**: Design callbacks expecting **additive semantics**, not replacement.

### TODO Marker Format

TODO comments follow a strict format for tooling and tracking:

```python
# TODO(<issue-id>): Brief description
# FIXME(code-puppy-xxx): Description with issue reference
# HACK(<category>): Temporary workaround with justification
# REVIEW(<username>): Flag for code review discussion
```

Examples:
```python
# TODO(code_puppy-123): Add retry logic for rate limits
# FIXME(code_puppy-456): Race condition on concurrent config updates
# HACK(pack-parallelism): Workaround for semaphore state sync
```

**Rule**: All TODOs **must include identifier**. Bare `TODO:` markers are discouraged.

### Test-Drift Prevention

Tests must prevent "drift" from implementation changes:

| Anti-Pattern | Prevention Strategy |
|--------------|---------------------|
| Mocking implementation details | Mock at boundary, not internals |
| Hardcoded expected values | Use property-based testing (hypothesis) |
| Ignoring error paths | Explicit error case coverage |
| Stale comment assertions | `pytest --doctest-modules` |

**CI Gate**: Plugin tests run on every plugin-related commit (see `scripts/git-hooks/pre-push`).

```python
# CORRECT: Test the invariant, not the implementation
@given(config=valid_config())
def test_effective_limit_always_positive(config):
    limiter = RunLimiter(config)
    assert limiter.effective_limit >= 1

# INCORRECT: Testing internal counter directly
def test_counter_increment():
    limiter._async_active = 1  # Brittle: relies on internal field
```

### Coverage Gates

Per-module coverage requirements (CI-enforced):

| Module Pattern | Minimum Coverage |
|---------------|------------------|
| `code_puppy/plugins/pack_parallelism/*` | ≥85% |
| `code_puppy/utils/file_display.py` | Tested via integration |
| `code_puppy/tools/command_runner.py` | Security-scanned + tested |

**Rule**: Coverage gates are **minimums**, not targets. Prefer quality over percentage.

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
