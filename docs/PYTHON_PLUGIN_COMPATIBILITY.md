# Python Plugin Compatibility Guide

> **Python plugins are the compatibility/legacy path only.** New plugin
> development should target the Elixir `PluginBehaviour` API. See
> [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md) for the primary development
> guide and [PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md) for
> the complete hook reference.
>
> Python `register_callbacks.py` plugins are supported for the legacy
> PyPI compatibility package and explicit bridge mode (`PUP_RUNTIME=python`
> / `--bridge-mode`). The Python freeze policy (see CONTRIBUTING.md)
> restricts new feature work in `code_puppy/**/*.py`.

---

## Table of Contents

1. [Writing a Python Plugin](#writing-a-python-plugin)
2. [The Trusted Local Code Model](#the-trusted-local-code-model)
3. [Sandboxing Decision](#sandboxing-decision)
4. [Security Checklist for Plugin Authors](#security-checklist-for-plugin-authors)
5. [Testing Your Plugin](#testing-your-plugin)
6. [Publishing and Distribution](#publishing-and-distribution)

---

## Writing a Python Plugin

### File Structure

```
code_puppy/plugins/my_feature/   # builtin
~/.code_puppy/plugins/my_feature/ # user
├── register_callbacks.py        # required — entry point
├── __init__.py                  # optional — makes it a proper package
├── helpers.py                   # optional — sub-modules
└── README.md                    # recommended — documentation
```

### Minimal Example

```python
# register_callbacks.py
from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info

def _on_startup():
    emit_info("🐾 my_feature is ready!")

register_callback("startup", _on_startup)
```

### Custom Slash Command

```python
# register_callbacks.py
from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info

def _custom_help():
    return [("hello", "Say hello (no model needed)")]

def _handle_command(command, name):
    if name == "hello":
        emit_info("👋 Hello from my_feature!")
        return True  # command handled, don't invoke model
    return None  # not our command

register_callback("custom_command_help", _custom_help)
register_callback("custom_command", _handle_command)
```

### Registering a Tool

```python
# register_callbacks.py
from code_puppy.callbacks import register_callback

def _register_tools():
    return [{
        "name": "my_tool",
        "register_func": _register_my_tool,
    }]

def _register_my_tool(agent):
    # Return a pydantic-ai compatible tool definition
    from pydantic import BaseModel

    class MyToolArgs(BaseModel):
        query: str

    async def my_tool(query: str) -> str:
        return f"Result for: {query}"

    return my_tool

register_callback("register_tools", _register_tools)
```

### Async Callbacks

Hooks that fire in async contexts accept both sync and async functions:

```python
import asyncio

async def _on_shutdown():
    # CORRECT: use async I/O
    await asyncio.sleep(0.1)

    # INCORRECT: never use blocking I/O in an async callback
    # time.sleep(1)  # ← blocks the event loop!

register_callback("shutdown", _on_shutdown)
```

**Rule**: If your callback is async, **all I/O must be async-native**.
Use `asyncio` primitives, not blocking stdlib calls.

### Key Python Conventions

| Convention | Rule |
|-----------|------|
| One `register_callbacks.py` per plugin | Module-scope registration only |
| 600-line file cap | Split into submodules if needed |
| Fail gracefully | Never crash the app — wrap in `try/except` |
> ⚠️ **Historical document.** The Python product (`code_puppy/`, `pyproject.toml`)
> has been removed from this repository. Python plugins are no longer supported.
> This document is preserved for migration context. New plugin development must
> target Elixir `PluginBehaviour` — see [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md).

| Return `None` from unhandled commands | Don't block other plugins |
| `PUP_` prefix for env vars | Legacy `PUPPY_` is deprecated |
| TODO markers need identifiers | `TODO(issue-id): description` |

---

## The Trusted Local Code Model

### Core Principle

> **User plugins are treated as trusted local Python/Elixir code.**
> They are imported and executed during plugin discovery with the same
> local privileges as Code Puppy itself.

This is an intentional design decision, not an oversight. Both runtimes
follow the same trust model:

| Property | Python Plugins | Elixir Plugins |
|----------|---------------|----------------|
| Execution privilege | Full user privileges | Full user privileges |
| File system access | Unrestricted | Unrestricted |
| Network access | Unrestricted | Unrestricted |
| Process spawning | Unrestricted | Unrestricted |
| Can crash the host? | Yes (uncaught exceptions) | No (compile/eval errors caught by loader; callback runtime exceptions caught by `Callbacks` error handling) |

### Why "Trusted Local"?

The trusted local model mirrors how shell scripts, `.bashrc`, `.vimrc`, and
similar user-level configurations work. When you put a file on your own
machine, you are vouching for its safety. Code Puppy does not insert an
intermediary trust boundary between the user and their own plugins.

This model trades maximal flexibility for an assumption of local trust.
It means plugin authors can:
- Import any system library
- Access the file system freely
- Make network requests
- Spawn subprocesses
- Interact with other tools on the system

### What This Means for Authors

1. **You have full power** — no sandbox restrictions to work around.
2. **Your users trust you** — they installed your plugin on their machine.
3. **Act responsibly** — document what your plugin accesses, avoid
   surprising side effects, and never exfiltrate data.
4. **Fail gracefully** — uncaught exceptions can crash the Python host.
   Always wrap risky operations in `try/except`.

### Security Guards That DO Exist

Despite the trusted model, Code Puppy enforces **path-level** security to
prevent accidental or trivial attacks:

| Guard | What It Catches | Runtime |
|-------|----------------|---------|
| Path traversal validation | `../` escapes in plugin names | Python + Elixir |
| Symlink escape detection | Symlinks pointing outside plugin dir | Python + Elixir |
| Canonical path resolution | Symlink chains that escape base dir | Python + Elixir |
| Regular file check | Device files, pipes, directories as plugins | Python |
| TOCTOU re-validation | Path swapped between validation and load | Python |
| User plugins opt-in | `enable_user_plugins=true` required (Python) | Python |
| Plugin allowlist | `allowed_user_plugins` config filter (Python) | Python |
| Crash isolation | Plugin compile/eval errors caught | Elixir |

These guards prevent **drive-by** attacks (e.g., a malicious symlink placed
in the plugins directory by another process) but do **not** prevent a
trusted plugin from doing harmful things once loaded.

---

## Sandboxing Decision

### Current Status: No Sandbox

Code Puppy does **not** sandbox plugin execution. This was an explicit
decision evaluated for both runtimes:

| Approach | Why Rejected |
|----------|-------------|
| **Python `subprocess` isolation** | Plugins need access to `register_callback`, `emit_info`, and the agent session. A subprocess can't call back into the host. |
| **Python `RestrictedPython`** | Too restrictive — blocks attribute access, imports, and comprehensions. Most useful plugins would break. |
| **Elixir separate BEAM node** | Adds IPC complexity and latency. No lightweight sandbox mechanism exists in BEAM. |
| **Container-based isolation** | Heavyweight; defeats the purpose of a local CLI tool. Breaks file system and process interaction. |
| **WASM sandboxing** | Python/Elixir runtimes lack mature WASM embedding. Would require a complete rewrite of the plugin API. |

### The Decision Rationale

From [ADR-006](adr/ADR-006-elixir-plugin-loader.md):

> *Security posture remains "trusted local code" — same as Python plugins.
> A sandboxed plugin runtime is a future consideration, not a blocker.*

The decision was made to **prioritize usability and power over isolation**
given that:

1. Plugins are **local files** — users must physically place them on disk.
2. The threat model is **self-harm**, not remote attack — you can only
   hurt yourself by installing a malicious plugin, just like installing
   any npm/pip/hex package.
3. Most useful plugins need **deep integration** with the host —
   accessing the session, emitting messages, hooking tool calls. A
   sandbox would neuter the feature set.

### Future Considerations

A sandbox model may be revisited if:
- A remote plugin marketplace is introduced (remote trust is different
  from local trust).
- A lightweight capability-based security model becomes practical for
  Python or Elixir.
- Community demand for audit/logging of plugin actions justifies the
  complexity.

For now, the trust model is: **if you put it on your machine, you own it.**

---

## Security Checklist for Plugin Authors

Before publishing or distributing a plugin, verify:

- [ ] **No credential harvesting** — Don't read OAuth tokens, API keys,
  or environment variables you don't need.
- [ ] **No unexpected network calls** — If your plugin phones home,
  document it clearly and let users opt out.
- [ ] **No file system surprises** — Only write to directories you own
  (under the plugin's data path or a user-configured location).
- [ ] **Graceful failure** — Wrap all risky operations in `try/except`
  (Python) or use supervision (Elixir). On the Elixir side, the loader
  catches compile/eval errors and `Callbacks` catches runtime exceptions
  — but your callback should still return sensible defaults rather than
  relying on the error sentinel. Never crash the host.
- [ ] **Documented side effects** — Your README should list every hook
  you register, every file you read/write, and every network endpoint
  you contact.
- [ ] **No privileged escalation** — Don't attempt to bypass
  `file_permission` or `run_shell_command` guards.
- [ ] **Clean uninstall** — Users should be able to remove your plugin
  directory without orphaned state. Clean up on `shutdown` if needed.
- [ ] **Env vars use `PUP_` prefix** — Never introduce new `PUPPY_`
  variables (deprecated).
- [ ] **TODO markers include identifiers** — `TODO(issue-id): description`,
  not bare `TODO: fix later`.

---

## Testing Your Plugin

### Python Plugin Testing

1. **Unit test your logic** — Extract business logic into testable
   functions separate from the `register_callbacks.py` registration.

2. **Mock at boundaries** — Don't mock `register_callback` internals;
   mock the hook system boundary:

   ```python
   # CORRECT: test the invariant
   def test_my_plugin_emits_on_startup():
       captured = []
       def fake_emit(msg): captured.append(msg)
       # ... test your _on_startup function ...

   # INCORRECT: testing internal registration details
   def test_register_callback_called():
       # This is testing the framework, not your plugin
   ```

3. **Test drift prevention** — Use property-based testing (hypothesis)
   for invariant checks, not hardcoded expected values.

4. **CI gate** — Plugin tests should be run explicitly via `mix test` or
   CI. The pre-push hook runs format + compile only (code-puppy-c1r); it does
   NOT run `mix test` to avoid 60s+ timeouts and side-effect commits.

### Elixir Plugin Testing

1. **Test the module directly** — Since plugins are proper modules
   implementing `PluginBehaviour`, you can unit test them normally.

2. **Use `Code.compile_file/1` in tests** — Simulates the actual
   discovery and loading path.

3. **Crash isolation tests** — Verify that a plugin with a compile
   error does not crash the host application.

### Coverage Gates

| Module Pattern | Minimum Coverage |
|---------------|------------------|
| `code_puppy/plugins/pack_parallelism/*` | ≥85% |
| `code_puppy/utils/file_display.py` | Integration-tested |
| `code_puppy/tools/command_runner.py` | Security-scanned + tested |

> **Rule**: Coverage gates are minimums, not targets. Prefer quality
> over percentage.

---

## Publishing and Distribution

### Builtin Plugins

Builtin plugins ship with Code Puppy in:
- `code_puppy/plugins/<name>/` (Python)
- `priv/plugins/<name>/` (Elixir)

To contribute a builtin plugin, open a PR following [CONTRIBUTING.md](../CONTRIBUTING.md).
Note: the **Python freeze** is in effect — new Python plugins require
justification (see the freeze policy).

### User Plugins (Local)

Users install local plugins by creating directories:
- Python: `~/.code_puppy/plugins/<name>/register_callbacks.py`
- Elixir: `~/.code_puppy_ex/plugins/<name>/register_callbacks.ex`

### Future: Hex Packages (Elixir)

ADR-006 documents a future `plugin.toml`/`plugin.json` manifest format
for package distribution. This is **not yet implemented**. When it
lands, Elixir plugins could be published via Hex:

```bash
mix hex.publish
```

And installed via:
```bash
# Future command — not yet available
/pup plugin install my_feature
```

### Future: pip Packages (Python)

Python plugin distribution via pip is not yet supported. Plugins must
be installed as local directories. A future packaging format may use
entry points:

```toml
# pyproject.toml (future — not yet supported)
[project.entry-points."code_puppy.plugins"]
my_feature = "my_feature.register_callbacks"
```

---

## Related Documentation

| Document | Description |
|----------|-------------|
| [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md) | Overview, quick start, Elixir & migration guides |
| [PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md) | Complete hook tables and merge semantics |
| [AGENTS.md](../AGENTS.md) | Contributor guide and hook list |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Python freeze policy |
| [ADR-006](./adr/ADR-006-elixir-plugin-loader.md) | Elixir plugin loader design |
