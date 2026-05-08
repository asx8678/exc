# Plugin Development & Migration Guide

> **Elixir plugins are the primary extension mechanism** for the native
> `pup` runtime (Burrito binary or escript). Python plugins are supported
> for the legacy PyPI compatibility package and bridge mode only.
>
> This guide covers the Elixir-primary plugin path, plugin discovery,
> and migration steps for Python→Elixir ports. For detailed reference
> material, see:
>
> - **[PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md)** — Complete
>   hook tables (Python + Elixir), merge semantics, and Python→Elixir
>   hook mapping.
> - **[PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md)**
>   — Python plugin writing guide, security model, sandboxing decision,
>   testing, and publishing.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Plugin Discovery](#plugin-discovery)
3. [Writing an Elixir Plugin](#writing-an-elixir-plugin)
4. [Migrating a Python Plugin to Elixir](#migrating-a-python-plugin-to-elixir)
5. [Common Pitfalls](#common-pitfalls)
6. [Troubleshooting](#troubleshooting)
7. [Related Documentation](#related-documentation)

---

## Quick Start

The fastest way to create a plugin depends on your target runtime:

**Elixir (Recommended — native runtime)** — `~/.code_puppy_ex/plugins/my_feature/register_callbacks.ex`:

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

**Python (Compatibility / Bridge Mode Only)** — `~/.code_puppy/plugins/my_feature/register_callbacks.py`:

```python
from code_puppy.callbacks import register_callback

def _on_startup():
    print("my_feature loaded!")

register_callback("startup", _on_startup)
```

That's it. The plugin loader auto-discovers `register_callbacks.*` files in
subdirectories. No manual loader registration, no config, no build step.

For Elixir: when both `register_callbacks.ex` and `register_callbacks.exs` exist,
`.ex` wins (preferred — compiles to BEAM).

> For the full Python plugin writing guide, security model, and testing
> details, see [PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md).

---

## Plugin Discovery

Code Puppy discovers plugins at startup by scanning well-known directories:

| Runtime | Builtin Location | User Location |
|---------|-----------------|---------------|
| **Elixir** (default) | `priv/plugins/<name>/register_callbacks.ex` | `~/.code_puppy_ex/plugins/<name>/register_callbacks.ex` |
| Python (compat) | `code_puppy/plugins/<name>/register_callbacks.py` | `~/.code_puppy/plugins/<name>/register_callbacks.py` |

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

### Custom Slash Command (Elixir)

Mirrors the Python custom command pattern using the `PluginBehaviour` API
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
| **New plugin development** | **Write an Elixir plugin.** Python `register_callbacks.py` is compat-only. |
| Python freeze is in effect | Only migrate if the feature is needed in the native `pup` runtime |
| Plugin is Python-only (no Elixir equivalent) | Write a new Elixir plugin; don't port 1:1 |
| Plugin uses the Elixir bridge | Good candidate — the bridge API is the same |
| Plugin is simple (few hooks) | Straightforward port |

### Migration Checklist

1. **Identify hooks used** — List every `register_callback` call in your
   Python plugin and find the Elixir equivalent. See the full
   [Python→Elixir Hook Mapping](./PLUGIN_HOOK_REFERENCE.md#pythontoxelixir-hook-mapping)
   in the hook reference.

2. **Create the module structure** — Define a module implementing
   `PluginBehaviour` with required `name/0` and `register/0`, plus
   optional `description/0`, `startup/0`, `shutdown/0`.
   Use `use CodePuppyControl.Plugins.PluginBehaviour` for default impls.

3. **Port business logic** — Rewrite Python logic in Elixir. Don't
   translate line-by-line; use idiomatic Elixir (pattern matching,
   pipes, supervised processes where appropriate).

4. **Handle async differences** — Python uses `asyncio`; Elixir uses
   processes and messages. No explicit `async/await` needed in Elixir.

5. **Test in isolation** — Place in `priv/plugins/` or
   `~/.code_puppy_ex/plugins/` and verify discovery.

6. **Update documentation** — Add a README.md to the plugin directory.

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

---

## Common Pitfalls

| Pitfall | Python | Elixir Fix |
|---------|--------|-----------|
| Blocking I/O in async callback | `time.sleep()` crashes event loop | Use `Process.sleep/1` or `:timer.sleep/1` — BEAM is preemptive |
| Global mutable state | Module-level dict | Use `Agent`, `ETS`, or `:persistent_term` |
| Exception crashes host | Unhandled exception propagates | Plugin loader catches compile/eval errors |
| Env var naming | `PUPPY_HOME` | Use `PUP_HOME` or `PUP_EX_HOME` per ADR-003 |
| File paths | `~/.code_puppy/` | Use `~/.code_puppy_ex/` for Elixir plugins |

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| Plugin not discovered | Wrong file name or location | Must be `register_callbacks.py`/`.ex` in a subdirectory of the plugins dir |
| Plugin crashes on load | Syntax error or import failure | Check logs; Python plugins can crash the host — use `try/except` |
| Hook not firing | Misspelled hook name | Compare against `callbacks.py` PhaseType literal |
| Multiple plugins conflict | Hook merge semantics unexpected | See [Hook Merge Semantics](./PLUGIN_HOOK_REFERENCE.md#hook-merge-semantics) |
| `load_prompt` not applied | Some agents don't call `on_load_prompt()` | Known inconsistency (UNK3) — not all agents call this hook |
| User plugin blocked | `enable_user_plugins` not set | Set `enable_user_plugins=true` in config (Python) |
| Elixir `.exs` plugin ignored | No module defined in `.exs` | `.exs` files must `defmodule` with `PluginBehaviour` |
| Path traversal rejected | Plugin name contains `../` or `\` | Use simple directory names — no special characters |
| Symlink escape rejected | Symlink points outside plugin dir | Make plugin a real directory, not a symlink |
| `PUPPY_` env var not working | Legacy prefix, deprecated | Switch to `PUP_` prefix |
| Plugin works in Python but not Elixir | Runtime API differences | See [Hook Mapping](./PLUGIN_HOOK_REFERENCE.md#pythontoxelixir-hook-mapping); hook signatures may differ |

---

## Related Documentation

| Document | Description |
|----------|-------------|
| [PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md) | Complete hook tables, merge semantics, Python→Elixir mapping |
| [PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md) | Python plugin writing, security model, testing, publishing |
| [plugins.md](./plugins.md) | Plugin quick-start and conventions overview |
| [AGENTS.md](../AGENTS.md) | Contributor guide, hook list, audit-driven rules |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | General contribution guidelines, Python freeze policy |
| [HOOKS.md](./HOOKS.md) | Shell hook system (Claude Code compatible) |
| [MIGRATION.md](./MIGRATION.md) | State migration: Python → Elixir home |
| [ADR-003](./adr/ADR-003-dual-home-config-isolation.md) | Dual-home config isolation |
| [ADR-004](./adr/ADR-004-python-to-elixir-migration-strategy.md) | Python → Elixir migration phases |
| [ADR-006](./adr/ADR-006-elixir-plugin-loader.md) | Elixir plugin loader design |
| [acceleration.md](./acceleration.md) | Native acceleration stack (Fast Puppy) |
| [config_spec.md](./config_spec.md) | Full configuration reference |
