# Code Puppy Architecture

> 🐶 *A comprehensive technical overview of the Code Puppy application architecture*

---

## Table of Contents

1. [High-Level Overview](#1-high-level-overview)
2. [Detailed Component Diagram](#2-detailed-component-diagram)
3. [Data Flow Diagrams](#3-data-flow-diagrams)
4. [Deployment Modes](#4-deployment-modes)
5. [Technology Stack](#5-technology-stack)
6. [Plugin Architecture](#6-plugin-architecture)

---

## 1. High-Level Overview

Code Puppy's runtime is **Elixir-native**. The `pup` binary (Burrito single-binary or escript) runs all core operations — CLI, TUI, agent execution, LLM calls, file ops, parsing, session state, and plugins — on the BEAM VM without any Python dependency.

> **ADR-005 boundary**: The Elixir runtime includes BEAM-native Python source
> *parsing* (lexer/parser via leex/yecc) for code analysis. This is parser data
> support, not Python runtime or product support.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CODE PUPPY ARCHITECTURE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │                        ELIXIR NATIVE CLI (pup)                       │  │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                │  │
│   │  │   CLI/TTY    │  │   TUI (Owl)  │  │   REPL       │                │  │
│   │  │   (Elixir)   │  │   (Elixir)   │  │   (Elixir)   │                │  │
│   │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                │  │
│   │         │                 │                 │                         │  │
│   │  ┌──────▼─────────────────▼─────────────────▼───────┐                 │  │
│   │  │         OTP Supervision Tree (BEAM)              │                 │  │
│   │  │  ┌────────────┐  ┌────────────┐  ┌────────────┐ │                 │  │
│   │  │  │ Run.Manager│  │  Agent     │  │  Session   │ │                 │  │
│   │  │  │ (GenServer)│  │  Manager   │  │  (Ecto)    │ │                 │  │
│   │  │  └────────────┘  └────────────┘  └────────────┘ │                 │  │
│   │  └──────────────────────────────────────────────────┘                 │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│         ┌──────────────────────────┼──────────────────────────┐            │
│         │                          │                          │            │
│   ┌─────▼──────────┐    ┌──────────▼──────┐    ┌─────────────▼──────┐     │
│   │ Provider       │    │ Tool.Runner     │    │ Callbacks / Hooks  │     │
│   │ Registry       │    │ (Elixir-native) │    │ (Elixir)           │     │
│   │ (LLM)          │    │                 │    │                    │     │
│   └────────────────┘    └──────────┬───────┘    └────────────────────┘     │
│                                     │                                      │
│   ┌─────────────────────────────────▼─────────────────────────────────┐   │
│   │                    ELIXIR SERVICES LAYER                          │   │
│   │                                                                   │   │
│   │   ┌────────────────┐  ┌────────────────┐  ┌────────────────┐     │   │
│   │   │  MessageCore   │  │    FileOps     │  │  Parsing.Parser│     │   │
│   │   │  (Messages)    │  │  (File Ops)    │  │  (leex/yecc)   │     │   │
│   │   ├────────────────┤  ├────────────────┤  ├────────────────┤     │   │
│   │   │ • Pruning      │  │ • list_files   │  │ • Symbols      │     │   │
│   │   │ • Hashing      │  │ • grep         │  │ • Highlights   │     │   │
│   │   │ • Serialize    │  │ • read_files   │  │ • Folds        │     │   │
│   │   │ • Token Est    │  │ • Batch Exec   │  │ • Batch Parse  │     │   │
│   │   └────────────────┘  └────────────────┘  └────────────────┘     │   │
│   └───────────────────────────────────────────────────────────────────┘   │
│                                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Runtime Responsibilities

| Runtime | Primary Role | Language | Process Model | Default |
|---------|-------------|----------|---------------|---------|
| **Elixir CLI/Runner** | All operations: CLI, TUI, agent exec, LLM calls, file ops, parsing, sessions, plugins | Elixir | BEAM VM (OTP) | ✅ **Default** |
| **Elixir OTP Control** | OTP supervision, PubSub, ETS state, scheduler | Elixir | BEAM VM | Always active |

---

## 2. Detailed Component Diagram

### Elixir Control Plane Components

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           ELIXIR CONTROL PLANE                                   │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                     PHOENIX / WEB LAYER                                       │ │
│  │                                                                             │ │
│  │   ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐│ │
│  │   │   HTTP Endpoint  │     │  WebSocket       │     │   REST API       ││ │
│  │   │   (Cowboy)       │     │  (Phoenix Ch.)    │     │   (Controllers)  ││ │
│  │   │                  │     │                  │     │                  ││ │
│  │   │ • /api/agents    │     │ • run:* topics   │     │ • /api/sessions  ││ │
│  │   │ • /api/sessions  │     │ • session:*      │     │ • /api/commands  ││ │
│  │   │ • /api/commands  │     │ • pubsub events  │     │ • /api/config    ││ │
│  │   └────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘│ │
│  └────────────┼────────────────────────┼────────────────────────┼──────────┘ │
│               │                        │                        │            │
│  ┌────────────▼────────────────────────▼────────────────────────▼────────────┐ │
│  │                         ROUTER / CHANNELS                                   │ │
│  │       ┌──────────────┐          ┌──────────────┐                        │ │
│  │       │  RunChannel  │          │ SessionChannel│                        │ │
│  │       │• join/leave  │          │• auth handling│                        │ │
│  │       │• command     │          │• history      │                        │ │
│  │       │• streaming   │          │• presence     │                        │ │
│  │       └──────┬───────┘          └───────┬───────┘                        │ │
│  └──────────────┼──────────────────────────┼────────────────────────────────┘ │
│                 │                          │                                  │
│  ┌──────────────▼──────────────────────────▼────────────────────────────────┐ │
│  │                         OTP SUPERVISION TREE                              │ │
│  │                                                                             │
│  │  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  │                    Application Supervisor                             │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │   │
│  │  │  │  PubSub     │  │ EventStore  │  │ RequestTrkr │  │ Run.Reg   │ │   │
│  │  │  │  (Phoenix)  │  │  (ETS)      │  │  (GenServer)│  │ (Registry)│ │   │
│  │  │  └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │   │
│  │  │                                                                       │   │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  │              MCP Server Supervisor (Dynamic)                    │   │ │
│  │  │  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │   │ │
│  │  │  │   │ MCP Server   │    │ MCP Server   │    │ MCP Server   │      │   │ │
│  │  │  │   │ Process      │    │ Process      │    │ Process      │ ... │   │ │
│  │  │  │   └──────────────┘    └──────────────┘    └──────────────┘      │   │ │
│  │  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │  │                                                                       │   │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  │              Scheduler (Oban)                                   │   │ │
│  │  │  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │   │ │
│  │  │  │   │ ScheduledTask│    │ CronTrigger  │    │ Queue Worker │      │   │ │
│  │  │  │   │ (PostgreSQL) │    │ (Cron expr)  │    │ (Executor)   │      │   │ │
│  │  │  │   └──────────────┘    └──────────────┘    └──────────────┘      │   │ │
│  │  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │  └───────────────────────────────────────────────────────────────────────┘   │
│  └──────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### Elixir Native Services

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ELIXIR RUNTIME SERVICES                                   │
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Message Processing (Elixir)                               │ │
│  │  Message serialization, token management, hashing, pruning                        │ │
│  │                                                                                   │ │
│  │  ┌────────────────────────────────────────────────────────────────────────────┐ │ │
│  │  │                           MessageBatch                                        │ │ │
│  │  │  High-performance message operations with ETS caching                         │ │ │
│  │  │  process() ─────────▶ ProcessResult (token counts, hashes)                   │ │ │
│  │  │  prune_and_filter() ─▶ PruneResult (interrupted tool removal)                 │ │ │
│  │  │  truncation_indices() ▶ List (protected token calc)                          │ │ │
│  │  │  split_for_summarization() ▶ SplitResult (binary partition)                  │ │ │
│  │  └────────────────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                                   │ │
│  │  Features:                                                                        │ │
│  │   • Incremental session serialization                                             │ │
│  │   • Token estimation (GPT-4, Claude, Gemini) with ETS caching                   │ │
│  │   • Hashline computation (line-level integrity)                                 │ │
│  │   • Fast message hashing with ETS memoization                                     │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                            File Operations (Elixir)                               │ │
│  │  Batch file operations with BEAM concurrency                                        │ │
│  │                                                                                   │ │
│  │   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                 │ │
│  │   │   list_files     │  │      grep        │  │   read_files     │                 │ │
│  │   │ • Recursive dir  │  │ • Regex search   │  │ • Multi-file     │                 │ │
│  │   │ • Metadata       │  │ • ripgrep-style  │  │ • Token count    │                 │ │
│  │   │ • Filtering      │  │ • Cross-file     │  │ • Range support  │                 │ │
│  │   └──────────────────┘  └──────────────────┘  └──────────────────┘                 │ │
│  │                                                                                   │ │
│  │   Batch Execution API:                                                            │ │
│  │   FileOps.batch(operations)            → Concurrent with dependencies            │ │
│  │   FileOps.batch_grouped(operations)    → Priority-based grouping                  │ │
│  │                                                                                   │ │
│  │   Features:                                                                       │ │
│  │    • BEAM process-based concurrency (lightweight)                              │ │
│  │    • Safety filtering (respects .gitignore)                                      │ │
│  │    • Result aggregation with timing                                                │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                           Parsing Service (Elixir)                              │ │
│  │  High-performance parsing with leex/yecc (BEAM-native)                        │ │
│  │                                                                                   │ │
│  │   Language Support:                                                               │ │
│  │   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │ │
│  │   │ Python   │ │ Rust     │ │ JavaScript│ │ TypeScript│ │ TSX      │ │ Elixir   │ │ │
│  │   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘ └─────────┘ │ │
│  │                                                                                   │ │
│  │   Capabilities:                                                                   │ │
│  │   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                 │ │
│  │   │ Symbol Extraction│  │ Syntax Highlight │  │ Code Folding     │                 │ │
│  │   │ • Functions      │  │ • Byte-accurate  │  │ • Function       │                 │ │
│  │   │ • Classes        │  │ • Per-line       │  │ • Class          │                 │ │
│  │   │ • Methods        │  │   ranges        │  │ • Conditional    │                 │ │
│  │   │ • Imports        │  │                  │  │ • Loop           │                 │ │
│  │   │ • Variables      │  │                  │  │ • Block          │                 │ │
│  │   └──────────────────┘  └──────────────────┘  └──────────────────┘                 │ │
│  │                                                                                   │ │
│  │   Additional:                                                                     │ │
│  │   • Diagnostics (syntax errors with positions)                                   │ │
│  │   • LRU cache for parsed trees                                                    │ │
│  │   • Batch parallel parsing                                                        │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                     Session & Credential Management                              │ │
│  │                                                                                   │ │
│  │   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                 │ │
│  │   │  Sessions (Ecto) │  │  Credentials     │  │  Config          │                 │ │
│  │   │  • SQLite        │  │  • API keys       │  │  • puppy.cfg     │                 │ │
│  │   │  • Oban          │  │  • OAuth tokens   │  │  • env vars      │                 │ │
│  │   │  • Auto-save     │  │  • Keychain       │  │  • Feature flags │                 │ │
│  │   └──────────────────┘  └──────────────────┘  └──────────────────┘                 │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         MCP Integration                                            │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                 │ │
│  │   │  MCP Manager   │  │ Circuit Breaker │  │ Security Layer   │                 │ │
│  │   │  (DynSupervisor)│  │ (Fault isolation)│  │ (Whitelist/     │                 │ │
│  │   │                 │  │                  │  │  Injection det.) │                 │ │
│  │   └──────────────────┘  └──────────────────┘  └──────────────────┘                 │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Flow Diagrams

### Agent Execution Flow

```
User Input (stdin or TUI)
    │
    ▼
┌──────────────────┐
│   pup CLI        │ ──► Parses args, loads Elixir config
│   (Burrito/      │
│    escript)      │
└──────┬───────────┘
       │
       ▼
┌──────────────────────┐
│  AgentManager        │ ──► Discovers/selects agent (GenServer)
│  (CodePuppyControl)  │
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│  AgentBehaviour      │ ──► Loads system prompt
│  (Elixir behaviour)  │ ──► Loads message history (ETS/EventStore)
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│  ProviderRegistry    │ ──► Resolves LLM provider
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│  HTTP Client         │ ──► Streaming request to LLM
│  (Elixir-native)     │ ──► SSE/chunk handling
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│  ModelOutput         │ ──► Text or tool calls
└──────┬───────────────┘
       │
       ├─────────────────────────┐
       │ (if text)               │ (if tool call)
       ▼                         ▼
┌──────────────┐       ┌──────────────────────┐
│ TUI/CLI out  │       │  Tool.Runner         │
│ (Owl/TTY)    │       │  (Elixir-native)     │
└──────────────┘       └──────┬───────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
       ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
       │ FileOps      │ │ Sub-agent    │ │ Shell Runner │
       │ (Elixir)     │ │ (Pack Lead)  │ │ (Safety)     │
       └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
              │               │               │
              └───────────────┼───────────────┘
                              │
                              ▼
                      ┌──────────────────┐
                      │ Tool Results     │
                      └──────┬───────────┘
                             │
                             ▼
                    (Back to LLM loop)
```

---

## 4. Deployment Modes

| Mode | Binary | Database | Scheduler | Admin UI | Use Case |
|------|--------|----------|-----------|----------|----------|
| **Burrito (recommended)** | `code_puppy_control_*` | ✅ SQLite + Oban | ✅ | ✅ Phoenix Endpoint | Daily driver |
| **Escript** | `pup` (escript) | ❌ | ❌ | ❌ | Dev / smoke testing only |

> The escript is a **degraded** runtime: no Repo/Oban/Phoenix Endpoint. For real work, prefer the Burrito binary.

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `PUP_EX_HOME` | Override Elixir home | `~/.code_puppy_ex/` |
| `PUP_DEBUG` | Enable debug logging | `0` |
| `PUPPY_HOME` | Legacy — logs deprecation warning | — |
| `PUP_HOME` | Deprecated — logs deprecation warning | — |

> New environment variables use the `PUP_` prefix per project convention. Legacy `PUPPY_`-prefixed variables are deprecated.

---

## 5. Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Runtime | Elixir | ~> 1.15 |
| VM | Erlang/OTP | 26+ |
| Web | Phoenix | 1.7+ |
| Database | Ecto + SQLite | — |
| Scheduler | Oban | — |
| LLM Clients | HTTPoison / Finch | — |
| Parsing | leex/yecc (BEAM-native) | — |
| Packaging | Burrito (Zig) | — |
| CLI | Optimus (arg parsing) | — |
| TUI | Owl | — |

### ADR-005: Python Parsing Boundary

The Elixir runtime includes BEAM-native Python source *parsing* (lexer/parser via leex/yecc):
- `elixir/code_puppy_control/lib/code_puppy_control/parsing/lexers/python_lexer.ex`
- `elixir/code_puppy_control/lib/code_puppy_control/parsing/parsers/python_parser.ex`
- `elixir/code_puppy_control/src/python_lexer.erl` / `.xrl`
- `elixir/code_puppy_control/src/python_parser.erl` / `.yrl`

These are **parser data support** — they enable Code Puppy to analyze Python source files for code context, symbol extraction, and syntax highlighting. They do **not** depend on or invoke a Python runtime. This boundary is documented in ADR-005.

---

## 6. Plugin Architecture

### Plugin Discovery

Code Puppy auto-discovers Elixir plugins at startup:

```
Plugin Loader (Elixir)
├── Builtin plugins: priv/plugins/<name>/register_callbacks.ex
└── User plugins: ~/.code_puppy_ex/plugins/<name>/register_callbacks.ex
```

Plugins implement `CodePuppyControl.Plugins.PluginBehaviour`:

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

### Hook System

Callbacks are registered via `Callbacks.register(:hook_name, fn)`. See `docs/PLUGIN_HOOK_REFERENCE.md` for the complete reference.

### Key Plugin Types

| Plugin Type | Examples |
|-------------|----------|
| Core | `fast_puppy` (status stub), `file_mentions`, `repo_compass`, `pack_parallelism` |
| Auth | `claude_code_oauth`, `chatgpt_oauth` |
| Feature | `agent_skills`, `turbo_executor`, `shell_safety`, `agent_trace`, `agent_memory`, `code_explorer`, `loop_detection` |

---

*Generated by Code Puppy 🐕*
