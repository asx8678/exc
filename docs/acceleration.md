# Runtime Selection & Acceleration

Code Puppy no longer has a separate "native acceleration" layer. The current
daily-driver runtime is **Elixir-native**: `CodePuppyControl` owns all core
execution on the BEAM.

The **Burrito native binary** (`code_puppy_control_<target>`) is the recommended
install — fully self-contained with no Erlang/Elixir/Python on the target. The
`./pup` escript is a degraded dev/smoke path (lacks Repo/Oban/Phoenix Endpoint).

> **ADR-005 boundary**: The Elixir runtime includes BEAM-native Python source
> *parsing* (lexer/parser via leex/yecc) for code analysis. This is parser data
> support, not Python runtime or product support.

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
└──────────────────────────────────────────────────────────────┘
```

## Capability Ownership

| Capability | Current owner | Python requirement |
|---|---|---|
| Message processing / pruning | Elixir (`MessageCore`) | None |
| File operations (`list_files`, `grep`, `read_file`) | Elixir (`FileOps`) | None |
| Repository indexing | Elixir | None |
| Parsing / symbol extraction | Elixir (`CodePuppyControl.Parsing.Parser`) | None |
| Agent execution / LLM streaming | Elixir runtime | None |

## Runtime Selection

| Need | Command / setting |
|---|---|
| **Default daily driver** | **Burrito `code_puppy_control_*` native binary** (recommended) |
| Dev / smoke testing | `./pup` escript (degraded: no Repo/Oban/Endpoint) |
| Build no-Python confidence | `mix pup_ex.smoke --no-python` |

## Fast Puppy Status

"Fast Puppy" is a historical name. The `/fast_puppy` command is a status stub
for users coming from older releases; it is not the control surface for routing,
profiles, or capability enablement.

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
