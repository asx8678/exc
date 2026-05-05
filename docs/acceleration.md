# Runtime Selection & Acceleration

Code Puppy no longer has a separate "native acceleration" layer bolted onto a
legacy Python-led CLI. The current daily-driver runtime is **Elixir-native**:
`CodePuppyControl` owns core execution on the BEAM, and Python is optional.

The **Burrito native binary** (`code_puppy_control_<target>`) is the recommended
install — fully self-contained with no Erlang/Elixir/Python on the target. The
`./pup` escript is a degraded dev/smoke path (lacks Repo/Oban/Phoenix Endpoint).

`PUP_RUNTIME=elixir` (or unset/`auto`) is the canonical no-Python runtime selector.

## Current Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Elixir-native `pup` CLI                    │
│              Burrito binary or `mix escript.build`            │
├──────────────────────────────────────────────────────────────┤
│  CodePuppyControl                                             │
│  • CLI / REPL / TUI coordination                              │
│  • Agent execution and session state                          │
│  • LLM providers and streaming                                │
│  • File operations, repository indexing, parsing              │
│  • Plugin callbacks, policy, scheduler, MCP                   │
└──────────────────────────────┬───────────────────────────────┘
                               │ optional, explicit only
┌──────────────────────────────▼───────────────────────────────┐
│                  Python compatibility bridge                  │
│        `PUP_RUNTIME=python` or `--bridge-mode` only            │
└──────────────────────────────────────────────────────────────┘
```

## Capability Ownership

| Capability | Current owner | Python requirement |
|---|---|---|
| Message processing / pruning | Elixir (`MessageCore`) | None |
| File operations (`list_files`, `grep`, `read_file`) | Elixir (`FileOps`) | None |
| Repository indexing | Elixir | None |
| Parsing / symbol extraction | Elixir (`CodePuppyControl.Parsing.Parser`) | None |
| Agent execution / LLM streaming | Elixir runtime | None on the default path |
| Legacy Python agents/plugins | Python bridge | Explicit bridge mode only |
| Legacy PyPI CLI (`code-puppy`) | Python package | Python compatibility path only |

## Runtime Selection

The Elixir runtime selector is controlled by `PUP_RUNTIME`:

| Value | Meaning |
|---|---|
| unset / `auto` | Default Elixir-first mode. Unknown/new capabilities stay in Elixir. |
| `elixir` | Force Elixir handling. |
| `python` | Explicitly delegate to the Python bridge. Requires a Python worker configuration. |

`--bridge-mode` on the Elixir CLI is equivalent to forcing
`PUP_RUNTIME=python` for that session.

`PUP_PYTHON_WORKER_SCRIPT` is **not** part of normal setup. It is required only
when you intentionally run the explicit Python bridge path (`PUP_RUNTIME=python`
or `--bridge-mode`) and the worker cannot otherwise be discovered/configured.

## Python Bridge Integration Pattern

Python compatibility code that needs to call into Elixir should go through the
bridge plugin:

```python
from code_puppy.plugins.elixir_bridge import is_connected, call_method

if is_connected():
    result = call_method("code_context.explore_file", {"file_path": path})
else:
    result = {"error": "Elixir bridge is not connected"}
```

Rules for new integrations:

1. Do **not** add a new backend facade or acceleration module.
2. Do **not** reintroduce profile switching for core capabilities.
3. Treat parsing as Elixir-owned; Python may provide narrowly scoped UI
   heuristics only when explicitly documented as a compatibility aid.
4. Fail gracefully when bridge mode is requested but the Python worker is not
   configured.

## Fast Puppy Status

"Fast Puppy" is now a historical name. Any remaining `/fast_puppy` command is a
status stub for users coming from older releases; it is not the control surface
for routing, profiles, or capability enablement.

Use these current controls instead:

| Need | Current control |
|---|---|
| **Default daily driver** | **Burrito `code_puppy_control_*` native binary** (recommended) |
| Force Elixir | `PUP_RUNTIME=elixir` |
| Dev / smoke testing | `./pup` escript (degraded: no Repo/Oban/Endpoint) |
| Explicit Python bridge | `PUP_RUNTIME=python` or `--bridge-mode` |
| Build no-Python confidence | `mix pup_ex.smoke --no-python` |

## Validation Commands

```bash
cd elixir/code_puppy_control
mix pup_ex.smoke --no-python
MIX_ENV=prod mix escript.build
./pup --version
```

For Burrito packaging:

```bash
cd elixir/code_puppy_control
scripts/build-burrito.sh --host-only
```

The default path should not require `python`, `python3`, or a Python worker
script. If a default-path command asks for `PUP_PYTHON_WORKER_SCRIPT`, that is a
bug in the Elixir-first runtime contract.
