# Plugin Migration Guide for Community Authors

> This guide helps plugin authors write, migrate, and publish plugins for
> Code Puppy. It covers both the **Python** runtime (`pup`) and the
> **Elixir** runtime (`pup-ex`), the security model, and practical
> migration steps.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Plugin Discovery](#plugin-discovery)
3. [The Trusted Local Code Model](#the-trusted-local-code-model)
4. [Sandboxing Decision](#sandboxing-decision)
5. [Writing a Python Plugin](#writing-a-python-plugin)
6. [Writing an Elixir Plugin](#writing-an-elixir-plugin)
7. [Migrating a Python Plugin to Elixir](#migrating-a-python-plugin-to-elixir)
8. [Hook Reference](#hook-reference)
9. [Hook Merge Semantics](#hook-merge-semantics)
10. [Security Checklist for Plugin Authors](#security-checklist-for-plugin-authors)
11. [Testing Your Plugin](#testing-your-plugin)
12. [Publishing and Distribution](#publishing-and-distribution)
13. [Troubleshooting](#troubleshooting)
14. [Related Documentation](#related-documentation)

---

## Quick Start

The fastest way to create a plugin is a single `register_callbacks` file:

**Python** — `~/.code_puppy/plugins/my_feature/register_callbacks.py`:

```python
from code_puppy.callbacks import register_callback

def _on_startup():
    print("my_feature loaded!")

register_callback("startup", _on_startup)
```

**Elixir** — `~/.code_puppy_ex/plugins/my_feature/register_callbacks.ex`:

```elixir
defmodule MyFeature do
  @moduledoc "My custom Code Puppy plugin."
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature"

  @impl true
  def description, do: "A sample plugin"

  @impl true
  def register do
    Callbacks.register(:startup, fn ->
      IO.puts("my_feature loaded!")
    end)
    :ok
  end
end
```

That's it. The plugin loader auto-discovers `register_callbacks.*` files in
subdirectories. No manual loader registration, no config, no build step.
When both `register_callbacks.ex` and `register_callbacks.exs` exist,
`.ex` wins (preferred — compiles to BEAM).

---

## Plugin Discovery

Code Puppy discovers plugins at startup by scanning well-known directories:

| Runtime | Builtin Location | User Location |
|---------|-----------------|---------------|
| Python | `code_puppy/plugins/<name>/register_callbacks.py` | `~/.code_puppy/plugins/<name>/register_callbacks.py` |
| Elixir | `priv/plugins/<name>/register_callbacks.ex` | `~/.code_puppy_ex/plugins/<name>/register_callbacks.ex` |

### Elixir-Specific: `.ex` vs `.exs`

The Elixir plugin loader supports two file extensions (see [ADR-006]):

| Extension | Compilation | BEAM Produced | Use When |
|-----------|-------------|---------------|----------|
| `.ex` | `Code.compile_file/1` | ✅ Yes | Production plugins — preferred |
| `.exs` | `Code.eval_file/1` | ❌ No | Quick scripts, prototyping |

When both `register_callbacks.ex` and `register_callbacks.exs` exist in the
same directory, `.ex` wins (preferred). All `.exs` files **must define a
module implementing `PluginBehaviour`** — inline scripts without a module are
not supported.

### Discovery Priority

1. **Builtin compiled modules** (Elixir only) — modules already in the BEAM
   that implement `PluginBehaviour`, discovered via `:code.all_loaded/0`.
2. **Builtin `priv/plugins/`** — shipped with Code Puppy, loaded at startup.
3. **User plugins** — from `~/.code_puppy/plugins/` (Python) or
   `~/.code_puppy_ex/plugins/` (Elixir).

All user plugins are loaded lazily in Python (deferred until first hook
trigger) and eagerly in Elixir (compiled/evaluated at startup).

[ADR-006]: adr/ADR-006-elixir-plugin-loader.md

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

### Custom Slash Command (Elixir)

Mirrors the Python example above using the real `PluginBehaviour` API
(see also the builtin `SampleCustomCommand` plugin in
`priv/plugins/sample_custom_command/`):

```elixir
# register_callbacks.ex
defmodule MyFeatureCommand do
  @moduledoc "Custom /hello slash command plugin."
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature_command"

  @impl true
  def description, do: "Custom /hello slash command"

  @impl true
  def register do
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    :ok
  end

  # Return help entries for the /help menu
  @spec command_help() :: [{String.t(), String.t()}]
  def command_help do
    [{"hello", "Say hello (no model needed)"}]
  end

  # Handle the command — return a string to display, or nil to pass
  @spec handle_command(String.t(), String.t()) :: String.t() | nil
  def handle_command(_command, name) do
    case name do
      "hello" -> "👋 Hello from my_feature!"
      _ -> nil  # not our command
    end
  end
end
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
| Return `None` from unhandled commands | Don't block other plugins |
| `PUP_` prefix for env vars | Legacy `PUPPY_` is deprecated |
| TODO markers need identifiers | `TODO(issue-id): description` |

---

## Writing an Elixir Plugin

### File Structure

```
priv/plugins/my_feature/            # builtin
~/.code_puppy_ex/plugins/my_feature/ # user
├── register_callbacks.ex           # preferred — compiles to BEAM
├── register_callbacks.exs          # fallback — evaluated, no BEAM
└── README.md                       # recommended
```

### Module Structure

Every Elixir plugin **must** define a module implementing `PluginBehaviour`.
Use the `use` macro to get default implementations for optional callbacks
(`startup/0`, `shutdown/0`, `description/0`):

```elixir
# register_callbacks.ex
defmodule MyFeature do
  @moduledoc "My custom Code Puppy plugin."
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature"

  @impl true
  def description, do: "A sample Code Puppy plugin"

  @impl true
  def register do
    Callbacks.register(:startup, fn ->
      IO.puts("🐾 my_feature is ready!")
    end)
    :ok
  end
end
```

**Required callbacks**: `name/0` (returns `String.t() | atom()`) and
`register/0` (calls `Callbacks.register/2`, returns `:ok | {:error, term()}`).

**Optional callbacks** (default `:ok` or `""` via `use` macro): `description/0`,
`startup/0`, `shutdown/0`. The deprecated `register_callbacks/0` (returning a
list of `{hook, fun}` tuples) is still supported for backward compatibility,
but `register/0` is preferred.

> **Important API notes**:
> - `init/1` and `version/0` are **not** part of `PluginBehaviour`.
>   Do not implement them.
> - Callback registration happens in `register/0` via
>   `CodePuppyControl.Callbacks.register/2`.
>   The function `Plugins.register_hook` does **not** exist.

### `.exs` (Script) Variant

```elixir
# register_callbacks.exs
# NOTE: Must still define a module implementing PluginBehaviour.
# Inline scripts without a module are NOT supported.

defmodule MyFeature do
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature"

  @impl true
  def register do
    Callbacks.register(:startup, fn ->
      IO.puts("my_feature loaded (from .exs)!")
    end)
    :ok
  end
end
```

### Key Elixir Conventions

| Convention | Rule |
|-----------|------|
| Prefer `.ex` over `.exs` | BEAM files enable hot-code upgrades; `.ex` wins when both exist |
| Always implement `PluginBehaviour` | Required for discovery and lifecycle |
| Use `Callbacks.register/2` in `register/0` | Not `Plugins.register_hook` — that API does not exist |
| No `init/1` or `version/0` | These are not part of `PluginBehaviour` |
| Crash isolation is provided | Plugin compile/eval errors caught by loader; callback runtime exceptions caught by `Callbacks` |
| No manual loader registration | The loader auto-discovers `register_callbacks.{ex,exs}` — no build step or config needed |
| Path traversal is blocked | Names with `..`, `/`, `\` are rejected |
| Symlink escapes are blocked | Canonical path must stay under base dir |

---

## Migrating a Python Plugin to Elixir

### When to Migrate

| Scenario | Recommendation |
|----------|---------------|
| Python freeze is in effect | Only migrate if the feature is needed in `pup-ex` |
| Plugin is Python-only (no Elixir equivalent) | Write a new Elixir plugin; don't port 1:1 |
| Plugin uses the Elixir bridge | Good candidate — the bridge API is the same |
| Plugin is simple (few hooks) | Straightforward port |

### Migration Checklist

1. **Identify hooks used** — List every `register_callback` call in your
   Python plugin and find the Elixir equivalent.

2. **Map Python hooks to Elixir hooks**:

   | Python Hook | Elixir Hook | Elixir Arity | Notes |
   |------------|-------------|-------------|-------|
   | `startup` | `:startup` | 0 | Direct mapping |
   | `shutdown` | `:shutdown` | 0 | Direct mapping |
   | `custom_command` | `:custom_command` | 2 | `(command, name)` — return `String.t() \| nil` |
   | `custom_command_help` | `:custom_command_help` | 0 | Returns `[{String.t(), String.t()}]` |
   | `register_tools` | `:register_tools` | 0 | Tool schema differs |
   | `load_prompt` | `:load_prompt` | 0 | Merge: `:concat_str` |
   | `agent_run_start` | `:agent_run_start` | 3 | `(agent_name, model_name, session_id)` |
   | `agent_run_end` | `:agent_run_end` | 6 | `(agent_name, model_name, session_id, success, error, response_text)` |
   | `stream_event` | `:stream_event` | 3 | Event format may differ |
   | `pre_tool_call` | `:pre_tool_call` | 3 | Blocking semantics differ |
   | `post_tool_call` | `:post_tool_call` | 5 | `(tool_name, tool_args, result, duration_ms, context)` |
   | `run_shell_command` | `:run_shell_command` | 3 | Fail-closed security hook |
   | `file_permission` | `:file_permission` | 6 | Fail-closed security hook |
   | `register_agents` | `:register_agents` | 0 | Merge: `:extend_list` |
   | `register_model_type` | `:register_model_types` | 0 | **Note plural** in Elixir; merge: `:extend_list` |
   | `load_model_config` | `:load_model_config` | 2 | Merge: `:update_map` |
   | `load_models_config` | `:load_models_config` | 0 | Merge: `:extend_list` |
   | `get_model_system_prompt` | `:get_model_system_prompt` | 3 | Chained, not merged |
   | `get_motd` | `:get_motd` | 0 | Merge: `:extend_list` |

   > **Elixir-only hooks** (no Python equivalent): `:version_check`/1,
   > `:agent_reload`/1, `:edit_file`/1, `:create_file`/1, `:replace_in_file`/1,
   > `:delete_snippet`/1, `:delete_file`/1, `:register_mcp_catalog_servers`/0,
   > `:register_browser_types`/0, `:register_model_providers`/0,
   > `:message_history_processor_start`/1, `:message_history_processor_end`/1.
   >
   > Arities come from `CodePuppyControl.Callbacks.Hooks`. When porting a
   > Python plugin, always verify the Elixir arity matches your callback
   > function — the signatures are not always 1:1.

3. **Create the module structure** — Define a module implementing
   `PluginBehaviour` with required `name/0` and `register/0`, plus
   optional `description/0`, `startup/0`, `shutdown/0`.
   Use `use CodePuppyControl.Plugins.PluginBehaviour` for default impls.

4. **Port business logic** — Rewrite Python logic in Elixir. Don't
   translate line-by-line; use idiomatic Elixir (pattern matching,
   pipes, supervised processes where appropriate).

5. **Handle async differences** — Python uses `asyncio`; Elixir uses
   processes and messages. No explicit `async/await` needed in Elixir.

6. **Test in isolation** — Place in `priv/plugins/` or
   `~/.code_puppy_ex/plugins/` and verify discovery.

7. **Update documentation** — Add a README.md to the plugin directory.

### Example Migration: Startup Hook

**Python**:
```python
# register_callbacks.py
from code_puppy.callbacks import register_callback
from code_puppy.messaging import emit_info

def _on_startup():
    emit_info("🐾 Session logger active!")

register_callback("startup", _on_startup)
```

**Elixir**:
```elixir
# register_callbacks.ex
defmodule SessionLogger do
  @moduledoc "Logs session activity."
  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "session_logger"

  @impl true
  def description, do: "Logs session start/end events"

  @impl true
  def register do
    Callbacks.register(:startup, fn ->
      IO.puts("🐾 Session logger active!")
    end)
    :ok
  end
end
```

### Common Pitfalls

| Pitfall | Python | Elixir Fix |
|---------|--------|-----------|
| Blocking I/O in async callback | `time.sleep()` crashes event loop | Use `Process.sleep/1` or `:timer.sleep/1` — BEAM is preemptive |
| Global mutable state | Module-level dict | Use `Agent`, `ETS`, or `:persistent_term` |
| Exception crashes host | Unhandled exception propagates | Plugin loader catches compile/eval errors |
| Env var naming | `PUPPY_HOME` | Use `PUP_HOME` or `PUP_EX_HOME` per ADR-003 |
| File paths | `~/.code_puppy/` | Use `~/.code_puppy_ex/` for Elixir plugins |

---

## Hook Reference

### Python Hooks

From `code_puppy/callbacks.py`:

| Hook | When | Signature | Can Block? |
|------|------|-----------|------------|
| `startup` | App boot | `() -> None` | No |
| `shutdown` | Graceful exit | `() -> None` | No |
| `invoke_agent` | Sub-agent invoked | `(*args, **kwargs) -> None` | No |
| `agent_exception` | Unhandled agent error | `(exception, *args, **kwargs) -> None` | No |
| `agent_run_start` | Before agent task | `(agent_name, model_name, session_id=None) -> None` | No |
| `agent_run_end` | After agent run | `(agent_name, model_name, session_id=None, success=True, error=None, response_text=None, metadata=None) -> None` | No |
| `load_prompt` | System prompt assembly | `() -> str \| None` | No |
| `get_model_system_prompt` | Per-model prompt | `(model_name, default_prompt, user_prompt) -> dict \| None` | No |
| `run_shell_command` | Before shell exec | `(context, command, cwd=None, timeout=60) -> dict \| None` | Yes (`{"blocked": True}`) |
| `file_permission` | Before file op | `(context, file_path, operation, ...) -> bool` | Yes (return `False`) |
| `pre_tool_call` | Before tool executes | `(tool_name, tool_args, context=None) -> Any` | Yes |
| `post_tool_call` | After tool finishes | `(tool_name, tool_args, result, duration_ms, context=None) -> Any` | No |
| `custom_command` | Unknown `/slash` cmd | `(command, name) -> True \| str \| None` | Yes (return `True`) |
| `custom_command_help` | `/help` menu | `() -> list[tuple[str, str]]` | No |
| `register_tools` | Tool registration | `() -> list[dict]` | No |
| `register_agents` | Agent catalogue | `() -> list[dict]` | No |
| `register_model_type` | Custom model type | `() -> list[dict]` | No |
| `load_model_config` | Patch model config | `(*args, **kwargs) -> Any` | No |
| `load_models_config` | Inject models | `() -> dict` | No |
| `stream_event` | Response streaming | `(event_type, event_data, agent_session_id=None) -> None` | No |
| `get_motd` | Banner | `() -> tuple[str, str] \| None` | No |

> **Full Python list**: See `code_puppy/callbacks.py` source for rarely-used hooks
> (e.g., `edit_file`, `create_file`, `replace_in_file`, `delete_snippet`,
> `delete_file`, `message_history_processor_start/end`).

### Elixir Hooks

From `CodePuppyControl.Callbacks.Hooks` — arities and merge strategies
are declared in the module; `Callbacks.register/2` validates the hook name
but **not** arity at registration time. A function with the wrong arity
fails when the hook is triggered and is handled as a callback failure
(`:callback_failed` sentinel), not at registration.

| Hook | Arity | Merge | Async | Description |
|------|-------|-------|-------|-------------|
| `:startup` | 0 | `:noop` | No | App boot |
| `:shutdown` | 0 | `:noop` | No | Graceful exit |
| `:invoke_agent` | 1 | `:noop` | Yes | Sub-agent invoked |
| `:agent_exception` | 2 | `:noop` | Yes | Unhandled agent error |
| `:agent_run_start` | 3 | `:noop` | Yes | Before agent task |
| `:agent_run_end` | 6 | `:noop` | Yes | After agent run |
| `:load_prompt` | 0 | `:concat_str` | No | System prompt assembly |
| `:get_model_system_prompt` | 3 | `:noop` | No | Per-model prompt (chained) |
| `:run_shell_command` | 3 | `:noop` | Yes | Shell exec (fail-closed) |
| `:file_permission` | 6 | `:noop` | Yes | File ops (fail-closed) |
| `:pre_tool_call` | 3 | `:noop` | Yes | Before tool executes |
| `:post_tool_call` | 5 | `:noop` | Yes | After tool finishes |
| `:custom_command` | 2 | `:noop` | No | Custom `/slash` cmd |
| `:custom_command_help` | 0 | `:extend_list` | No | `/help` menu |
| `:register_tools` | 0 | `:extend_list` | No | Tool registration |
| `:register_agents` | 0 | `:extend_list` | No | Agent catalogue |
| `:register_model_types` | 0 | `:extend_list` | No | Custom model type (**plural** — differs from Python `register_model_type`) |
| `:load_model_config` | 2 | `:update_map` | No | Patch model config |
| `:load_models_config` | 0 | `:extend_list` | No | Inject models |
| `:stream_event` | 3 | `:noop` | Yes | Response streaming |
| `:get_motd` | 0 | `:extend_list` | No | Banner |
| `:version_check` | 1 | `:noop` | Yes | Check for updates |
| `:agent_reload` | 1 | `:noop` | No | Agent hot-reload |
| `:edit_file` | 1 | `:noop` | No | File edit observer |
| `:create_file` | 1 | `:noop` | No | File create observer |
| `:replace_in_file` | 1 | `:noop` | No | File replace observer |
| `:delete_snippet` | 1 | `:noop` | No | Snippet delete observer |
| `:delete_file` | 1 | `:noop` | No | File delete observer |
| `:register_mcp_catalog_servers` | 0 | `:extend_list` | No | MCP catalog servers |
| `:register_browser_types` | 0 | `:extend_list` | No | Browser type providers |
| `:register_model_providers` | 0 | `:extend_list` | No | Model providers |
| `:message_history_processor_start` | 1 | `:noop` | Yes | Before msg history processing |
| `:message_history_processor_end` | 1 | `:noop` | Yes | After msg history processing |

> **Full Elixir list**: Call `CodePuppyControl.Callbacks.Hooks.all/0` for the
> authoritative source. `Hooks` declares each hook's expected arity and
> merge strategy; `Callbacks.register/2` validates the hook name only.
> A function with the wrong arity will fail when the hook is triggered
> and is handled as a callback failure (`:callback_failed` sentinel),
> not at registration time.

---

## Hook Merge Semantics

When multiple plugins register for the same hook, results are **merged**
according to the hook's declared strategy (see `Callbacks.Hooks` in Elixir
or `callbacks.py` in Python):

| Merge Strategy | Python Analogy | Elixir Atom | Example |
|---------------|---------------|-------------|---------|
| String concatenation | `str` → concatenate | `:concat_str` | Two `load_prompt` hooks append to the system prompt |
| List extend | `list` → extend | `:extend_list` | Two `register_tools` hooks combine their tool lists |
| Map update (later wins) | `dict` → update | `:update_map` | Two `load_models_config` hooks merge model dicts |
| Boolean OR | `bool` → OR | `:or_bool` | Two hooks returning `bool`: any `True` wins |
| No merge (collect raw) | `None` → ignored | `:noop` | Hook results collected as-is |

> **Security hooks use `:noop` merge, not `:or_bool`**: Both
> `file_permission` and `run_shell_command` have `merge: :noop` in Elixir.
> Results are collected as-is and interpreted by the **caller** with
> fail-closed semantics — any callback returning a deny (or failing with
> an exception) blocks the operation. Do **not** assume OR aggregation
> for security hooks; a single `False` / `:deny` always wins.

**Design rule**: Write callbacks expecting **additive semantics**, not
replacement. Your `load_prompt` return will be *appended* to the prompt,
not replace it. Your `register_tools` list will be *merged* with other
plugins' tools.

```python
# CORRECT: additive — appends custom instructions
def my_prompt():
    return "\n\n## Custom Instructions\nAlways use type hints."

# INCORRECT: replacement — overwrites everything (doesn't actually work)
def my_prompt_bad():
    return "NEW SYSTEM PROMPT"  # This gets concatenated, not replaced
```

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

4. **CI gate** — Plugin tests run on every plugin-related commit
   (see `scripts/git-hooks/pre-push`).

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
/pup-ex plugin install my_feature
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

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| Plugin not discovered | Wrong file name or location | Must be `register_callbacks.py`/`.ex` in a subdirectory of the plugins dir |
| Plugin crashes on load | Syntax error or import failure | Check logs; Python plugins can crash the host — use `try/except` |
| Hook not firing | Misspelled hook name | Compare against `callbacks.py` PhaseType literal |
| Multiple plugins conflict | Hook merge semantics unexpected | Remember: `str` → concatenate, `dict` → later wins, `list` → extend |
| `load_prompt` not applied | Some agents don't call `on_load_prompt()` | Known inconsistency (UNK3) — not all agents call this hook |
| User plugin blocked | `enable_user_plugins` not set | Set `enable_user_plugins=true` in config (Python) |
| Elixir `.exs` plugin ignored | No module defined in `.exs` | `.exs` files must `defmodule` with `PluginBehaviour` |
| Path traversal rejected | Plugin name contains `../` or `\` | Use simple directory names — no special characters |
| Symlink escape rejected | Symlink points outside plugin dir | Make plugin a real directory, not a symlink |
| `PUPPY_` env var not working | Legacy prefix, deprecated | Switch to `PUP_` prefix |
| Plugin works in Python but not Elixir | Runtime API differences | See migration section; hook signatures may differ |

---

## Related Documentation

| Document | Description |
|----------|-------------|
| [AGENTS.md](../AGENTS.md) | Contributor guide, hook list, audit-driven rules |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | General contribution guidelines, Python freeze policy |
| [HOOKS.md](./HOOKS.md) | Shell hook system (Claude Code compatible) |
| [MIGRATION.md](./MIGRATION.md) | State migration: Python → Elixir home |
| [ADR-003](./adr/ADR-003-dual-home-config-isolation.md) | Dual-home config isolation |
| [ADR-004](./adr/ADR-004-python-to-elixir-migration-strategy.md) | Python → Elixir migration phases |
| [ADR-006](./adr/ADR-006-elixir-plugin-loader.md) | Elixir plugin loader design |
| [acceleration.md](./acceleration.md) | Native acceleration stack (Fast Puppy) |
| [config_spec.md](./config_spec.md) | Full configuration reference |
