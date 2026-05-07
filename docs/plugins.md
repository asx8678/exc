# Code Puppy Plugin Development

> **Default extension mechanism for the native `pup` runtime.**

Plugins are the primary way to extend Code Puppy. **Elixir plugins implementing
`PluginBehaviour` are the only supported path** for new development.

For the full plugin development and migration guide, see
**[PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md)**. For the complete hook
reference, see **[PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md)**.

---

## Quick Start: Elixir Plugin

### Builtin Plugin

Create a directory under `priv/plugins/` with a `register_callbacks.ex` file:

```
priv/plugins/my_feature/
├── register_callbacks.ex    # required — entry point (preferred, compiles to BEAM)
└── README.md                # recommended
```

```elixir
# register_callbacks.ex
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
      IO.puts("🐾 my_feature loaded!")
    end)
    :ok
  end
end
```

### User Plugin

Place the same structure under the user plugins directory:

```
~/.code_puppy_ex/plugins/my_feature/
├── register_callbacks.ex    # preferred — compiles to BEAM
└── register_callbacks.exs   # fallback — evaluated, no BEAM
```

The loader auto-discovers `register_callbacks.ex` (preferred) and
`register_callbacks.exs` (fallback) in subdirectories. No manual
registration, config, or build step required.

---

## Required Callbacks

Every Elixir plugin must implement `PluginBehaviour`:

| Callback | Required | Returns |
|----------|----------|---------|
| `name/0` | ✅ Yes | `String.t() \| atom()` |
| `register/0` | ✅ Yes | `:ok \| {:error, term()}` |
| `description/0` | No (default `""`) | `String.t()` |
| `startup/0` | No (default `:ok`) | `:ok` |
| `shutdown/0` | No (default `:ok`) | `:ok` |

Use `use CodePuppyControl.Plugins.PluginBehaviour` to get default
implementations for optional callbacks.

> **Important**: `init/1` and `version/0` are NOT part of `PluginBehaviour`.
> Do not implement them. Register callbacks in `register/0` via
> `Callbacks.register/2`, not `Plugins.register_hook` (that API does not exist).

---

## Common Patterns

### Custom Slash Command

```elixir
defmodule MyFeatureCommand do
  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks

  @impl true
  def name, do: "my_feature_command"

  @impl true
  def register do
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    :ok
  end

  def command_help, do: [{"hello", "Say hello (no model needed)"}]

  def handle_command(_command, "hello"), do: "👋 Hello from my_feature!"
  def handle_command(_command, _name), do: nil
end
```

### Adding to the System Prompt

```elixir
@impl true
def register do
  Callbacks.register(:load_prompt, fn ->
    "\n\n## My Plugin Instructions\nAlways use type hints."
  end)
  :ok
end
```

### Registering Tools

```elixir
@impl true
def register do
  Callbacks.register(:register_tools, fn ->
    [%{name: "my_tool", register_func: &my_tool_definition/0}]
  end)
  :ok
end
```

---

## File Extensions: `.ex` vs `.exs`

| Extension | Compilation | BEAM Produced | Use When |
|-----------|-------------|---------------|----------|
| `.ex` | `Code.compile_file/1` | ✅ Yes | Production plugins — **preferred** |
| `.exs` | `Code.eval_file/1` | ❌ No | Quick scripts, prototyping |

When both exist in the same directory, `.ex` wins. All `.exs` files must
still define a module implementing `PluginBehaviour` — inline scripts
without a module are not supported.

---

## Security Model

User plugins execute arbitrary code with full system privileges — the same
trust model as shell scripts or `.bashrc`. This applies to both Elixir and
Python user plugins.

| Guard | What It Catches |
|-------|----------------|
| Path traversal validation | `../` escapes in plugin names |
| Symlink escape detection | Symlinks pointing outside plugin dir |
| Canonical path resolution | Symlink chains that escape base dir |
| Crash isolation (Elixir) | Plugin compile/eval/runtime errors caught |

**There is no sandbox.** Only install plugins from sources you trust.

---

## Conventions

| Convention | Rule |
|-----------|------|
| Prefer `.ex` over `.exs` | BEAM files enable hot-code upgrades |
| Always implement `PluginBehaviour` | Required for discovery and lifecycle |
| Use `Callbacks.register/2` in `register/0` | Not `Plugins.register_hook` — that doesn't exist |
| No `init/1` or `version/0` | Not part of the behaviour |
| Crash isolation is provided | Loader catches errors; host never crashes |
| Path traversal/symlink guards | Names with `../`, `/`, `\` are rejected |
| 600-line file cap | Split into submodules if needed |
| Fail gracefully | Return sensible defaults, not exceptions |
| `PUP_` prefix for env vars | Legacy `PUPPY_` is deprecated |

---

## Python Plugins (Compatibility Bridge Only)

> **Note:** Python `register_callbacks.py` plugins were part of the legacy
> Python product that has been removed from this repository. New plugin
> development must target Elixir `PluginBehaviour`.

```
(removed — Python plugins no longer supported)
```

The Python freeze policy (see CONTRIBUTING.md) restricts new feature work
in `code_puppy/**/*.py`. New plugins should target the Elixir `PluginBehaviour`
API instead.

For the full Python plugin guide, see
**[PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md)**.
For the hook mapping and reference, see
**[PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md)**.

---

## Related Documentation

| Document | Description |
|----------|-------------|
| [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md) | Overview, quick start, Elixir & migration guides |
| [PLUGIN_HOOK_REFERENCE.md](./PLUGIN_HOOK_REFERENCE.md) | Complete hook tables, merge semantics, Python→Elixir mapping |
| [PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md) | Historical: Python compat plugin docs (legacy, pre-deletion) |
| [ADR-006](./adr/ADR-006-elixir-plugin-loader.md) | Elixir plugin loader design decisions |
| [AGENTS.md](../AGENTS.md) | Contributor guide and hook list |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Contribution guidelines |
| [HOOKS.md](./HOOKS.md) | Shell hook system (Claude Code compatible) |
