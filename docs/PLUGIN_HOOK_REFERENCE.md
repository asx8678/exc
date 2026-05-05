# Plugin Hook Reference

> Complete reference for all Code Puppy plugin hooks — Python and Elixir runtimes,
> merge semantics, and Python→Elixir hook mapping for migration.
>
> For plugin development guides, see [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md).
> For Python compatibility details, see [PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md).

---

## Table of Contents

1. [Python Hooks](#python-hooks)
2. [Elixir Hooks](#elixir-hooks)
3. [Python→Elixir Hook Mapping](#pythontoxelixir-hook-mapping)
4. [Elixir-Only Hooks](#elixir-only-hooks)
5. [Hook Merge Semantics](#hook-merge-semantics)

---

## Python Hooks

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

---

## Elixir Hooks

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
| `:agent_run_end` | 7 | `:noop` | Yes | After agent run |
| `:load_prompt` | 0 | `:concat_str` | No | System prompt assembly |
| `:get_model_system_prompt` | 3 | `:noop` | No | Per-model prompt (chained) |
| `:run_shell_command` | 3 | `:noop` | Yes | Shell exec (fail-closed) |
| `:file_permission` | 6 | `:or_bool` | Yes | File ops (fail-closed) |
| `:pre_tool_call` | 3 | `:noop` | Yes | Before tool executes |
| `:post_tool_call` | 5 | `:noop` | Yes | After tool finishes |
| `:custom_command` | 2 | `:noop` | No | Custom `/slash` cmd |
| `:custom_command_help` | 0 | `:extend_list` | No | `/help` menu |
| `:register_tools` | 0 | `:extend_list` | No | Tool registration |
| `:register_agents` | 0 | `:extend_list` | No | Agent catalogue |
| `:register_model_type` | 0 | `:extend_list` | No | Custom model type (maps from Python `register_model_type`) |
| `:load_model_config` | 2 | `:update_map` | No | Patch model config |
| `:load_models_config` | 0 | `:update_map` | No | Inject models |
| `:stream_event` | 3 | `:noop` | Yes | Response streaming |
| `:get_motd` | 0 | `:noop` | No | Banner |
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
| `:message_history_processor_start` | 4 | `:noop` | Yes | Before msg history processing |
| `:message_history_processor_end` | 5 | `:noop` | Yes | After msg history processing |

> **Full Elixir list**: Call `CodePuppyControl.Callbacks.Hooks.all/0` for the
> authoritative source. `Hooks` declares each hook's expected arity and
> merge strategy; `Callbacks.register/2` validates the hook name only.
> A function with the wrong arity will fail when the hook is triggered
> and is handled as a callback failure (`:callback_failed` sentinel),
> not at registration time.
>
> **Note on arities**: This table reflects the current `Callbacks.Hooks`
> module. If arities change between releases, `Hooks.all/0` is always
> the ground truth. When in doubt, run:
> ```elixir
> iex -S mix
> iex> CodePuppyControl.Callbacks.Hooks.all() |> Enum.map(fn {k, v} -> {k, v.arity} end)
> ```

---

## Python→Elixir Hook Mapping

When migrating a Python plugin to Elixir, use this mapping to find
the equivalent hook:

| Python Hook | Elixir Hook | Elixir Arity | Notes |
|------------|-------------|-------------|-------|
| `startup` | `:startup` | 0 | Direct mapping |
| `shutdown` | `:shutdown` | 0 | Direct mapping |
| `custom_command` | `:custom_command` | 2 | `(command, name)` — return `String.t() \| nil` |
| `custom_command_help` | `:custom_command_help` | 0 | Returns `[{String.t(), String.t()}]` |
| `register_tools` | `:register_tools` | 0 | Tool schema differs |
| `load_prompt` | `:load_prompt` | 0 | Merge: `:concat_str` |
| `agent_run_start` | `:agent_run_start` | 3 | `(agent_name, model_name, session_id)` |
| `agent_run_end` | `:agent_run_end` | 7 | `(agent_name, model_name, session_id, success, error, response_text, metadata)` |
| `stream_event` | `:stream_event` | 3 | Event format may differ |
| `pre_tool_call` | `:pre_tool_call` | 3 | Blocking semantics differ |
| `post_tool_call` | `:post_tool_call` | 5 | `(tool_name, tool_args, result, duration_ms, context)` |
| `run_shell_command` | `:run_shell_command` | 3 | Fail-closed security hook |
| `file_permission` | `:file_permission` | 6 | Fail-closed security hook |
| `register_agents` | `:register_agents` | 0 | Merge: `:extend_list` |
| `register_model_type` | `:register_model_type` | 0 | Merge: `:extend_list` |
| `load_model_config` | `:load_model_config` | 2 | Merge: `:update_map` |
| `load_models_config` | `:load_models_config` | 0 | Merge: `:extend_list` |
| `get_model_system_prompt` | `:get_model_system_prompt` | 3 | Chained, not merged |
| `get_motd` | `:get_motd` | 0 | Merge: `:noop` |

> Arities come from `CodePuppyControl.Callbacks.Hooks`. When porting a
> Python plugin, always verify the Elixir arity matches your callback
> function — the signatures are not always 1:1.

---

## Elixir-Only Hooks

These hooks have no Python equivalent:

| Hook | Arity | Description |
|------|-------|-------------|
| `:version_check` | 1 | Check for updates |
| `:agent_reload` | 1 | Agent hot-reload |
| `:edit_file` | 1 | File edit observer |
| `:create_file` | 1 | File create observer |
| `:replace_in_file` | 1 | File replace observer |
| `:delete_snippet` | 1 | Snippet delete observer |
| `:delete_file` | 1 | File delete observer |
| `:register_mcp_catalog_servers` | 0 | MCP catalog servers |
| `:register_browser_types` | 0 | Browser type providers |
| `:register_model_providers` | 0 | Model providers |
| `:message_history_processor_start` | 4 | Before msg history processing |
| `:message_history_processor_end` | 5 | After msg history processing |

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

## Related Documentation

| Document | Description |
|----------|-------------|
| [PLUGIN_MIGRATION.md](./PLUGIN_MIGRATION.md) | Overview, quick start, Elixir & Python writing guides |
| [PYTHON_PLUGIN_COMPATIBILITY.md](./PYTHON_PLUGIN_COMPATIBILITY.md) | Python compat details, testing, security model |
| [AGENTS.md](../AGENTS.md) | Contributor guide and hook list |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Python freeze policy |
| [ADR-006](./adr/ADR-006-elixir-plugin-loader.md) | Elixir plugin loader design |
