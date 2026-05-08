# ADR-006: Elixir Plugin Loader — Discovery, Compilation, and Security

## Status

**ACCEPTED** (2026-05-25)

## Context

Phase F of the Python-to-Elixir migration (ADR-004) requires a fully
featured Elixir plugin loader. The existing `CodePuppyControl.Plugins.Loader`
already supports:

- **Builtin compiled plugins** — modules in `CodePuppyControl.Plugins.*`
  implementing `PluginBehaviour`, discovered via `:code.all_loaded/0`
- **Builtin `priv/plugins/` plugins** — `.ex` files auto-discovered under
  `priv/plugins/<name>/register_callbacks.ex`, compiled at runtime
- **User plugins** — `.ex` files under `~/.code_puppy_ex/plugins/`,
  compiled at runtime with path-traversal and symlink-escape guards

However, three gaps must be resolved before F.2–F.6 can begin:

1. **No `.exs` script support** — Elixir convention uses `.exs` for
   non-compiled, runtime-evaluated scripts. The Python side auto-discovers
   `register_callbacks.py` — the Elixir side should also discover
   `register_callbacks.exs`.
2. **Static vs dynamic compilation decision is undocumented** — Should
   builtin plugins in `priv/plugins/` be compiled at build time (static) or
   at runtime (dynamic)? Both approaches have trade-offs.
3. **Cross-runtime parity is incomplete** — Python discovers
   `register_callbacks.py`; Elixir discovers `register_callbacks.ex` but
   not `register_callbacks.exs`. Users familiar with Elixir conventions
   expect `.exs` for scripting.

## Decision

### D1: Support both `.ex` and `.exs` in plugin discovery

The plugin loader will discover files matching either extension:

| File Pattern | Discovery Priority | Compilation |
|---|---|---|
| `register_callbacks.ex` | **1st** (preferred) | `Code.compile_file/1` — produces `.beam` |
| `register_callbacks.exs` | **2nd** (fallback) | `Code.eval_file/1` — no `.beam`, but MUST define a `PluginBehaviour` module |

When both exist, `register_callbacks.ex` wins. This mirrors Python's
single-file convention (`register_callbacks.py`) while honoring Elixir's
`.ex` vs `.exs` convention for compiled vs interpreted modules.

**Rationale**: `.ex` files are proper Elixir modules compiled to BEAM
bytecode. They can implement behaviours, define structs, and participate
in the type system. `.exs` files are evaluated (not compiled to `.beam`),
but **must still define a module implementing `PluginBehaviour`**. This
ensures all plugins have a name, type, and lifecycle — properties that
inline scripts (no module) cannot provide. The only difference between
`.ex` and `.exs` is the compilation method; the structural requirement
remains the same.

### D2: Builtin plugins — static compilation for `priv/plugins/*.ex`

**Builtin plugins in `priv/plugins/` that use `.ex` files are compiled at
runtime via `Code.compile_file/1`, NOT at build time.** This is the
existing behaviour and we keep it.

The static-compilation alternative (adding `priv/plugins/` to
`elixirc_paths` in `mix.exs`) was rejected because:

| Factor | Static (build-time) | Dynamic (runtime) |
|---|---|---|
| **Deployment** | Plugins baked into release — users must rebuild to change | Plugins are files on disk — users can edit without rebuild |
| **Burrito packaging** | Increases binary size; plugins immutable | Plugins remain editable under `priv/` in the unpacked Burrito sandbox |
| **Hot-reloading** | Requires OTP code_server + `Code.purge/1` dance | Already supported via `Code.compile_file/1` |
| **Discovery parity** | Breaks parity with Python side (Python auto-discovers at runtime) | Matches Python's runtime discovery model |
| **Test isolation** | Compiled modules are global — test contamination risk | Runtime compilation enables per-test isolation |
| **Complexity** | Requires custom Mix compiler step + `elixirc_paths` wiring | Zero build system changes — `priv/` stays as-is |

**The decision: keep dynamic compilation for builtin `priv/plugins/`.**

`.exs` files in `priv/plugins/` are evaluated via `Code.eval_file/1`.
Like `.ex` files, they **must define a module implementing
`PluginBehaviour`**. No BEAM files are produced, but the module is
available in-memory for introspection and lifecycle management.

### D3: User plugins — `.code_puppy_ex/plugins/` with security guards

User plugins live under `~/.code_puppy_ex/plugins/` (per ADR-003
dual-home isolation). Discovery rules mirror builtin:

1. Scan `~/.code_puppy_ex/plugins/<name>/` for subdirectories
2. Per subdirectory, look for `register_callbacks.ex` (preferred) or
   `register_callbacks.exs` (fallback)
3. Validate canonical paths against the plugins base directory
4. Reject path-traversal attempts (`..`, `/`, `\`, null bytes in names)
5. Reject symlink escapes (canonical path must remain under base dir)
6. Compile/evaluate and register plugins implementing `PluginBehaviour`

**Security model is unchanged from the existing loader**: user plugins
execute arbitrary Elixir code with full system privileges. This is
documented as a known security posture (same as Python plugins). A
sandboxed plugin runtime is a future consideration, not a blocker.

### D4: Plugin manifest (optional, future-proofing)

Each plugin directory MAY contain a `plugin.toml` or `plugin.json`
manifest file. If present, the loader reads it for metadata (name,
version, dependencies) before compilation. If absent, the loader
falls back to discovering the module name from the compiled code.

**This is explicitly NOT implemented in Phase F.1.** It is documented
here as a future extension point so that later phases don't need a
new ADR to add it. The absence of a manifest is the default case.

## Implementation Specification

### Discovery Algorithm

```
load_all():
  builtin_modules = discover compiled PluginBehaviour modules
  builtin_priv    = discover priv/plugins/<name>/register_callbacks.{ex,exs}
  user_plugins    = discover ~/.code_puppy_ex/plugins/<name>/register_callbacks.{ex,exs}
  return %{builtin: [...], user: [...]}
```

Per-plugin directory:

```
discover_plugin(dir, base_dir):
  ex  = dir/register_callbacks.ex   (if exists)
  exs = dir/register_callbacks.exs  (if exists)

  file = ex OR exs OR first *.ex in dir OR first *.exs in dir
  if no file found: skip

  validate safe_plugin_path?(file, base_dir)

  if file ends with .ex:
    Code.compile_file(file) → find PluginBehaviour modules → register
  elif file ends with .exs:
    Code.eval_file(file)   → find PluginBehaviour modules → register
    # NOTE: .exs files MUST define a PluginBehaviour module.
    # Inline scripts with no module are not supported.
```

### Compilation Semantics

| Extension | Function | BEAM Produced | Module Available | Re-load |
|---|---|---|---|---|
| `.ex` | `Code.compile_file/1` | ✅ Yes (in-memory) | ✅ Yes | Call `Code.compile_file/1` again |
| `.exs` | `Code.eval_file/1` | ❌ No | Only if `defmodule` with `PluginBehaviour` is in the script | Call `Code.eval_file/1` again |

**Key difference**: `Code.compile_file/1` is preferred because it
produces proper BEAM modules that survive hot-code upgrades.
`Code.eval_file/1` evaluates the script without producing a `.beam`
file, but the script must still define a `PluginBehaviour` module.
Inline scripts that merely execute side effects without defining a
module are NOT supported — they lack identity, lifecycle hooks,
and cannot be tracked or cleaned up by the loader.

### Security Invariants

1. **Path traversal**: Plugin names containing `..`, `/`, `\`, or null
   bytes are rejected
2. **Symlink escape**: Canonical path of every loaded file must remain
   under the base plugins directory
3. **No writes to legacy home**: User plugins resolve via
   `Paths.plugins_dir()` which uses `PUP_EX_HOME` / `~/.code_puppy_ex/`
   (per ADR-003)
4. **Crash isolation**: Plugin compile/eval errors are caught and logged;
   they never crash the host application

## Alternatives Considered

### A1: Static compilation only (no runtime loading)

**Rejected**: Breaks parity with Python. Prevents users from adding
plugins without rebuilding. Does not support the Burrito-packaged
distribution model where `priv/` is on disk.

### A2: Mix-based plugin compilation (custom compiler step)

**Rejected**: Requires modifying `mix.exs` and the build pipeline.
Adds complexity for minimal gain — runtime compilation is already
fast and well-tested. Would also prevent hot-reloading.

### A3: Erlang `:code.load_abs/1` for pre-compiled `.beam` files

**Rejected for Phase F.1**: Could be useful for distribution of
pre-compiled plugin packages in the future, but adds deployment
complexity (`.beam` files are OTP-version dependent). Deferred to
a potential Phase F.7 if packaging demand emerges.

### A4: Sandbox plugins in a separate BEAM instance

**Rejected for Phase F.1**: Elixir has no lightweight sandbox
mechanism. Running plugins in a separate node adds IPC complexity
and latency. Security posture remains "trusted local code" —
same as Python plugins.

## Consequences

### Positive

- **Cross-runtime parity**: Elixir discovers `register_callbacks.{ex,exs}`
  just as Python discovers `register_callbacks.py`
- **Ergonomic for plugin authors**: `.exs` for simple scripts, `.ex` for
  proper modules — authors choose their comfort level
- **No build system changes**: Dynamic compilation keeps `mix.exs` and
  the release pipeline untouched
- **Hot-reload ready**: Runtime compilation means plugins can be
  re-loaded without restarting the application
- **Future-proof**: Plugin manifest extension point documented without
  implementation overhead

### Negative

- **Runtime compilation cost**: Each `.ex` file is compiled on every
  startup. For the current set of builtin plugins (≈5 files), this adds
  <100ms. For large plugin directories, this could become noticeable.
  Mitigation: plugin count is expected to stay small; if it grows,
  consider a compile cache or lazy loading.
- **`.exs` modules lack `.beam` files**: A `.exs` file that defines
  a `defmodule` with `@behaviour PluginBehaviour` works at runtime,
  but the module won't have a `.beam` file. This limits introspection
  and hot-code upgrade. Mitigation: documented as "prefer `.ex` for
  production plugins". Inline `.exs` scripts without a module are
  NOT supported (see Decision D1 rationale).
- **No sandboxing**: User plugins run with full privileges. This is
  the same posture as Python but is worth restating.

## CI Gates

| Gate | Test | Rationale |
|---|---|---|
| GATE-F1-1 | `.ex` plugin in `priv/plugins/` loads and registers callbacks | Proves builtin discovery |
| GATE-F1-2 | `.exs` plugin in `priv/plugins/` loads and registers callbacks | Proves `.exs` support |
| GATE-F1-3 | `.ex` preferred over `.exs` when both exist | Proves priority ordering |
| GATE-F1-4 | User plugin in `~/.code_puppy_ex/plugins/` loads correctly | Proves user discovery with dual-home isolation |
| GATE-F1-5 | Symlink escape in user plugins is rejected | Proves security invariant |
| GATE-F1-6 | Path traversal in plugin names is rejected | Proves security invariant |
| GATE-F1-7 | Plugin compile error does not crash application | Proves crash isolation |
| GATE-F1-8 | `load_all/0` is idempotent | Proves dedup |

## References

- [ADR-003](ADR-003-dual-home-config-isolation.md) — Dual-home config isolation
- [ADR-004](ADR-004-python-to-elixir-migration-strategy.md) — Phase F: Plugins
- [HOOKS.md](../HOOKS.md) — Callback hook reference
- Python plugin system: `code_puppy/plugins/__init__.py`
- Elixir plugin system: `lib/code_puppy_control/plugins/loader.ex`

---

**Decision Date**: 2026-05-25
**Decision Maker**: Code Puppy Migration Team
**Status**: Accepted
