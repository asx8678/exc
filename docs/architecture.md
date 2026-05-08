# Code Puppy Architecture

> 🐶 *A comprehensive technical overview of the Code Puppy application architecture*

---

## Table of Contents

1. [High-Level Overview](#1-high-level-overview)
2. [Detailed Component Diagram](#2-detailed-component-diagram)
3. [Data Flow Diagrams](#3-data-flow-diagrams)
4. [Protocol Details](#4-protocol-details)
5. [Deployment Modes](#5-deployment-modes)
6. [Technology Stack](#6-technology-stack)
7. [Plugin Architecture](#7-plugin-architecture)

---

## 1. High-Level Overview

Code Puppy's default runtime is **Elixir-native**. The `pup` binary (Burrito single-binary or escript) runs all core operations — CLI, TUI, agent execution, LLM calls, file ops, parsing, session state, and plugins — without any Python dependency.

Python is **optional** and used only for legacy/PyPI compatibility, Python plugins/agents, or explicit bridge-worker mode (`PUP_RUNTIME=python` / `--bridge-mode`).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CODE PUPPY ARCHITECTURE (Current)                        │
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
│   │  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  │                 │  │
│   │  │  │ Run.Manager│  │  Agent     │  │  Session   │  │                 │  │
│   │  │  │ (GenServer)│  │  Manager   │  │  (Ecto)    │  │                 │  │
│   │  │  └────────────┘  └────────────┘  └────────────┘  │                 │  │
│   │  └──────────────────────────────────────────────────┘                 │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│         ┌──────────────────────────┼──────────────────────────┐            │
│         │                          │                          │            │
│   ┌─────▼──────────┐    ┌──────────▼──────┐    ┌─────────────▼──────┐     │
│   │ Provider       │    │ Tool.Runner     │    │ Callbacks / Hooks  │     │
│   │ Registry       │    │ (Elixir-native) │    │ (Elixir, legacy    │     │
│   │ (LLM)          │    │                 │    │  Python compat)    │     │
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
│   ┌─────────────────────────────────────────────────────────────────┐     │
│   │  PYTHON BRIDGE (Optional / Legacy)                              │     │
│   │  PythonWorker.Port — JSON-RPC 2.0 over stdio                   │     │
│   │  Bridge-mode only (PUP_RUNTIME=python / --bridge-mode)        │     │
│   └─────────────────────────────────────────────────────────────────┘     │
│                                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Runtime Responsibilities

| Runtime | Primary Role | Language | Process Model | Default |
|---------|-------------|----------|---------------|---------|
| **Elixir CLI/Runner** | All operations: CLI, TUI, agent exec, LLM calls, file ops, parsing, sessions, plugins | Elixir | BEAM VM (OTP) | ✅ **Default** |
| **Elixir OTP Control** | OTP supervision, PubSub, ETS state, scheduler | Elixir | BEAM VM | Always active |
| **Python Bridge** (*optional*) | Legacy compatibility bridge for `PUP_RUNTIME=python` | Python 3.12+ | Asyncio + ThreadPool | ❌ Optional |

---

## 2. Detailed Component Diagram

> **Historical: Python Runtime Components**
>
> The Python runtime was the original primary runtime (pre-Phase H). It remains
> available as a bridge-worker for `PUP_RUNTIME=python` mode. The default Elixir
> runtime now implements all of these components natively.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            PYTHON RUNTIME (Legacy Bridge)                        │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         ENTRY LAYER (Python CLI)                            │ │
│  │   ┌───────────────┐      ┌───────────────┐      ┌───────────────┐        │ │
│  │   │   __main__.py │─────▶│   AppRunner   │─────▶│     main()    │        │ │
│  │   └───────────────┘      └───────────────┘      └───────┬───────┘        │ │
│  │                                                          ▼                 │ │
│  │                                               ┌───────────────┐           │ │
│  │                                               │  interactive  │           │ │
│  │                                                │     loop      │           │ │
│  │                                                └───────────────┘           │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                 AGENT ECOSYSTEM (Legacy Python)                             │ │
│  │   ┌──────────────────────────────────────────────┐                         │ │
│  │   │         BaseAgent (ABC) — Python only        │                         │ │
│  │   │  • PydanticAI integration                    │                         │ │
│  │   │  • Tool execution & streaming                │                         │ │
│  │   └────────┬─────────────────────────┬──────────┘                         │ │
│  │            │                         │                                    │ │
│  │   ┌────────▼──────────┐   ┌──────────▼──────────┐                        │ │
│  │   │   CodePuppyAgent  │   │   PackLeaderAgent    │                        │ │
│  │   └───────────────────┘   └──────────────────────┘                        │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                     TOOL LAYER (Legacy Python)                              │ │
│  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │ │
│  │   │   File Ops   │  │   Shell Cmd  │  │   Browser    │  │   Agents     │  │ │
│  │   │  (read/grep) │  │  (run_shell) │  │  (Puppeteer) │  │  (invoke)    │  │ │
│  │   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                     TURBO ORCHESTRATOR (Legacy)                             │ │
│  │      ┌───────────────┐     ┌───────────────┐     ┌───────────────┐       │ │
│  │      │     Plan      │────▶│  Validate     │────▶│  Execute      │       │ │
│  │      └───────────────┘     └───────────────┘     └───────┬───────┘       │ │
│  │                                                           │               │ │
│  │      ┌───────────────┐     ┌───────────────┐     ┌───────▼───────┐       │ │
│  │      │   FileOps     │     │   TreeSitter  │     │  Python-only  │       │ │
│  │      │   (Elixir)    │     │   (Elixir)    │     │  (Elixir now) │       │ │
│  │      └───────────────┘     └───────────────┘     └───────────────┘       │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│  > **Note**: The Turbo Orchestrator was a Python-only batch system. In the       │
│  > Elixir runtime, batch file operations use `FileOps.batch/1` directly.          │
└─────────────────────────────────────────────────────────────────────────────────┘
```

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
│  │   │   (Cowboy)       │     │  (Phoenix Ch.)   │     │   (Controllers)  ││ │
│  │   │                  │     │                  │     │                  ││ │
│  │   │ • /api/agents    │     │ • run:* topics   │     │ • /api/sessions  ││ │
│  │   │ • /api/sessions  │     │ • session:*      │     │ • /api/commands  ││ │
│  │   │ • /api/commands  │     │ • pubsub events  │     │ • /api/config    ││ │
│  │   └────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘│ │
│  │            │                        │                        │          │ │
│  └────────────┼────────────────────────┼────────────────────────┼──────────┘ │
│               │                        │                        │            │
│  ┌────────────▼────────────────────────▼────────────────────────▼────────────┐ │
│  │                         ROUTER / CHANNELS                                   │ │
│  │                                                                             │ │
│  │       ┌──────────────┐          ┌──────────────┐                        │ │
│  │       │  RunChannel  │          │ SessionChannel│                        │ │
│  │       │              │          │               │                        │ │
│  │       │• join/leave  │          │• auth handling│                        │ │
│  │       │• command     │          │• history      │                        │ │
│  │       │• streaming   │          │• presence     │                        │ │
│  │       └──────┬───────┘          └───────┬───────┘                        │ │
│  │              │                          │                                │ │
│  └──────────────┼──────────────────────────┼────────────────────────────────┘ │
│                 │                          │                                  │
│  ┌──────────────▼──────────────────────────▼────────────────────────────────┐ │
│  │                         OTP SUPERVISION TREE                              │ │
│  │                                                                             │ │
│  │  ┌─────────────────────────────────────────────────────────────────────┐   │ │
│  │  │                    Application Supervisor                             │   │ │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │   │ │
│  │  │  │  PubSub     │  │ EventStore  │  │ RequestTrkr │  │ Run.Reg   │ │   │ │
│  │  │  │  (Phoenix)  │  │  (ETS)      │  │  (GenServer)│  │ (Registry)│ │   │ │
│  │  │  └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │   │ │
│  │  │                                                                       │   │ │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐   │   │ │
│  │  │  │              MCP Server Supervisor (Dynamic)                    │   │ │
│  │  │  │                                                                 │   │ │
│  │  │  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │   │ │
│  │  │  │   │ MCP Server   │    │ MCP Server   │    │ MCP Server   │      │   │ │
│  │  │  │   │ Process      │    │ Process      │    │ Process      │ ...  │   │ │
│  │  │  │   └──────────────┘    └──────────────┘    └──────────────┘      │   │ │
│  │  │  └─────────────────────────────────────────────────────────────────┘   │   │ │
│  │  │                                                                       │   │ │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐   │   │ │
│  │  │  │              PythonWorker Supervisor (Dynamic) — Optional       │   │ │
│  │  │  │  Only started when PUP_RUNTIME=python (legacy bridge mode)     │   │ │
│  │  │  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │   │ │
│  │  │  │   │ PythonWorker │    │ PythonWorker │    │ PythonWorker │      │   │ │
│  │  │  │   │   Port #1    │    │   Port #2    │    │   Port #3    │  ... │   │ │
│  │  │  │   │  (run: abc)  │    │  (run: xyz)  │    │  (run: 123)  │      │   │ │
│  │  │  │   └──────────────┘    └──────────────┘    └──────────────┘      │   │ │
│  │  │  └─────────────────────────────────────────────────────────────────┘   │   │ │
│  │  │                                                                       │   │ │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐   │   │ │
│  │  │  │              Scheduler (Oban)                                   │   │ │
│  │  │  │                                                                 │   │ │
│  │  │  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │   │ │
│  │  │  │   │ ScheduledTask│    │ CronTrigger  │    │ Queue Worker │      │   │ │
│  │  │  │   │ (PostgreSQL) │    │ (Cron expr)  │    │ (Executor)   │      │   │ │
│  │  │  │   └──────────────┘    └──────────────┘    └──────────────┘      │   │ │
│  │  │  └─────────────────────────────────────────────────────────────────┘   │   │ │
│  │  └───────────────────────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                    │
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
│  │  │                                                                             │ │ │
│  │  │  process() ─────────▶ ProcessResult (token counts, hashes)                   │ │ │
│  │  │  prune_and_filter() ─▶ PruneResult (interrupted tool removal)                 │ │ │
│  │  │  truncation_indices() ▶ List (protected token calc)                          │ │ │
│  │  │  split_for_summarization() ▶ SplitResult (binary partition)                  │ │ │
│  │  └────────────────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                                   │ │
│  │  Features:                                                                        │ │
│  │   • Message serialization for pydantic-ai objects                                 │ │
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
│  │   │                  │  │                  │  │                  │                 │ │
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
│  │                           Tree-sitter Parsing (Elixir)                              │ │
│  │  High-performance parsing with tree-sitter via Elixir NIF                        │ │
│  │                                                                                   │ │
│  │   Language Support:                                                               │ │
│  │   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │ │
│  │   │ Python   │ │ Rust     │ │ JavaScript│ │ TypeScript│ │ TSX      │ │ Elixir   │ │ │
│  │   │   ⭐ T1   │ │   ⭐ T1   │ │   ⭐ T1    │ │   ⭐ T1    │ │   🟡 T2   │ │ 🟠 T3    │ │ │
│  │   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘ └─────────┘ │ │
│  │                                                                                   │ │
│  │   Capabilities:                                                                   │ │
│  │   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                 │ │
│  │   │ Symbol Extraction│  │ Syntax Highlight │  │ Code Folding     │                 │ │
│  │   │                  │  │                  │  │                  │                 │ │
│  │   │ • Functions      │  │ • Tree-sitter    │  │ • Function       │                 │ │
│  │   │ • Classes        │  │   queries          │  │ • Class          │                 │ │
│  │   │ • Methods        │  │ • Helix Editor     │  │ • Conditional    │                 │ │
│  │   │ • Imports        │  │   capture names    │  │ • Loop           │                 │ │
│  │   │ • Variables      │  │ • Byte-accurate  │  │ • Block          │                 │ │
│  │   └──────────────────┘  └──────────────────┘  └──────────────────┘                 │ │
│  │                                                                                   │ │
│  │   Additional:                                                                     │ │
│  │   • Diagnostics (syntax errors with positions)                                   │ │
│  │   • Incremental parsing (fast re-parse for edits)                                  │ │
│  │   • LRU cache for parsed trees                                                    │ │
│  │   • Batch parallel parsing                                                        │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                       │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Flow Diagrams

### CLI Mode Flow (Elixir-Native Default)

```
┌──────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────┐
│   User   │     │   pup (Elixir)   │     │  Agent Runtime   │     │   LLM API    │
│          │     │  (Burrito/escript)│     │  (BEAM OTP)      │     │  (OpenAI/    │
│          │     │                  │     │  (GenServer)     │     │  Anthropic)  │
└────┬─────┘     └──────┬───────────┘     └────────┬─────────┘     └──────┬───────┘
     │                  │                          │                     │
     │  Type prompt     │                          │                     │
     │─────────────────▶│                          │                     │
     │                  │                          │                     │
     │                  │  Route to AgentManager   │                     │
     │                  │─────────────────────────▶│                     │
     │                  │                          │                     │
     │                  │                          │  Build messages     │
     │                  │                          │  + tool schemas     │
     │                  │                          │─────────────────────▶│
     │                  │                          │                     │
     │                  │                          │◀────────────────────│
     │                  │                          │   Streaming response│
     │                  │                          │                     │
     │                  │◀─────────────────────────│   Events (text/    │
     │                  │   Events via PubSub/Ets  │   tool_calls)      │
     │                  │                          │                     │
     │◀─────────────────│   Display (Owl/TTY)      │                     │
     │   See response   │                          │                     │
     │                  │                          │                     │
     │  [Tool needed]   │                          │                     │
     │  ─ ─ ─ ─ ─ ─ ─ ─ │                          │                     │
     │                  │  ┌──────────────────┐    │                     │
     │                  │  │ Tool.Runner      │    │                     │
     │                  │  │ (Elixir-native)  │    │                     │
     │                  │  │                  │    │                     │
     │                  │  │• read_file       │◀───│                     │
     │                  │  │• list_files      │    │                     │
     │                  │  │• grep            │────▶│                     │
     │                  │  │• run_shell       │    │  Return results     │
     │                  │  └──────────────────┘    │─────────────────────▶
     │                  │                          │
     │◀─────────────────│   Tool output shown      │
     │   View results   │   in conversation        │
     │                  │                          │
```

> **Note**: In legacy `PUP_RUNTIME=python` mode, the tool layer delegates to
> a Python subprocess via `PythonWorker.Port` (see Bridge Mode below).

### Bridge Mode Flow (Legacy: Elixir → Python Bridge)

> **Legacy Mode** — The default Elixir-native runtime does not use bridge mode.
> Bridge mode is only activated when `PUP_RUNTIME=python` is set, or when
> the user explicitly invokes the legacy Python CLI with `--bridge-mode`.
>
Python bridge mode is activated either by passing `--bridge-mode` to the Python CLI or by setting `CODE_PUPPY_BRIDGE=1` or `PUP_RUNTIME=python`. The CLI shim sets the environment variable before importing the full application runtime so the bridge plugin freezes `BRIDGE_ENABLED=True` during plugin discovery. Once startup callbacks run, the bridge plugin emits `bridge.ready`, starts its stdin reader, and `AppRunner` keeps the event loop alive until the bridge controller handles `exit` and marks itself stopped.

```
┌─────────────┐    ┌───────────────┐    ┌───────────────────┐    ┌───────────────┐
│   Client    │    │   Phoenix     │    │ PythonWorker.Port │    │   Python      │
│  (Web/WS)   │    │   (Elixir)    │    │   (OTP Process)   │    │   Worker      │
└──────┬──────┘    └───────┬───────┘    └─────────┬─────────┘    └───────┬───────┘
       │                   │                      │                      │
       │  POST /api/runs   │                      │                      │
       │  {agent, prompt}  │                      │                      │
       │──────────────────▶│                      │                      │
       │                   │                      │                      │
       │                   │  Spawn Port         │                      │
       │                   │  with run_id        │                      │
       │                   │─────────────────────▶│                      │
       │                   │                      │                      │
       │                   │                      │  Launch Python      │
       │                   │                      │  pup --bridge-mode   │
       │                   │                      │  (or CODE_PUPPY_    │
       │                   │                      │   BRIDGE=1)          │
       │                   │                      │─────────────────────▶
       │                   │                      │                      │
       │                   │◀─────────────────────│  Port initialized     │
       │                   │  Port ready          │  send: initialize     │
       │                   │                      │                      │
       │                   │─────────────────────▶│                      │
       │                   │  JSON-RPC: run.start │                      │
       │                   │  Content-Length      │                      │
       │                   │  framing             │                      │
       │                   │                      │  Relay to agent     │
       │                   │                      │  runtime            │
       │                   │                      │─────────────────────▶
       │                   │                      │                      │
       │◀──────────────────│  WebSocket upgrade   │                      │
       │  WS: /socket    │  (optional)          │                      │
       │  join: run:*    │                      │                      │
       │                   │                      │◀─────────────────────│
       │                   │                      │  run.status         │
       │                   │                      │  run.event          │
       │                   │                      │  run.completed      │
       │                   │                      │  run.failed         │
       │                   │                      │  (notifications)    │
       │                   │                      │                      │
       │                   │◀─────────────────────│                      │
       │                   │  PubSub.broadcast    │                      │
       │                   │  run:run_id          │                      │
       │                   │                      │                      │
       │◀──────────────────│  WS events           │                      │
       │  {type, data}   │  {type, data}        │                      │
       │  streamed        │                      │                      │
       │                   │                      │                      │
       │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
       │                   │                      │     ERROR PATH        │
       │                   │                      │                      │
       │                   │  ◀─── Port crash ────│                      │
       │                   │                      │                      │
       │                   │  Registry.lookup    │                      │
       │                   │  Run.State.set_status│  (failed)            │
       │                   │  PubSub: run_failed   │                      │
       │◀──────────────────│                      │                      │
       │  Error event     │                      │                      │
```

### WebSocket Event Flow

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                         WEBSOCKET EVENT FLOW                                   │
│                                                                                │
│   ┌─────────────┐        ┌─────────────┐        ┌─────────────┐              │
│   │   Browser   │◀──────▶│   Phoenix   │◀──────▶│   PubSub    │              │
│   │    Client   │   WS   │   Channel   │   IPC   │   (ETS)     │              │
│   └─────────────┘        └──────┬──────┘        └──────┬──────┘              │
│                                 │                      │                      │
│                                 ▼                      ▼                      │
│                          ┌─────────────┐        ┌─────────────┐             │
│                          │ RunChannel  │◀──────▶│ EventStore  │             │
│                          │             │        │   (ETS)     │             │
│                          └─────────────┘        └─────────────┘             │
│                                                                                │
│   Event Types:                                                                 │
│   ═══════════                                                                  │
│                                                                                │
│   ┌────────────────┬─────────────────────────────────────────────────────────┐ │
│   │ Type           │ Payload Example                                         │ │
│   ├────────────────┼─────────────────────────────────────────────────────────┤ │
│   │ text           │ {content: "Hello...", chunk: false, run_id}             │ │
│   │ tool_result    │ {tool_name, result, tool_call_id, run_id}              │ │
│   │ status         │ {status: "running|paused|completed", run_id}            │ │
│   │ prompt         │ {prompt_id, question, options, run_id}                  │ │
│   │ completed      │ {result, token_usage, duration_ms, run_id}             │ │
│   │ failed         │ {error, stack_trace, run_id}                           │ │
│   └────────────────┴─────────────────────────────────────────────────────────┘ │
│                                                                                │
│   Subscription Pattern:                                                          │
│   ═══════════════════                                                          │
│                                                                                │
│   Client connects:                                                             │
│   → join("run:" <> run_id)                                                    │
│   → Phoenix.Tracker marks presence                                              │
│   → Client receives all events for that run                                     │
│                                                                                │
│   Server publishes:                                                            │
│   → Phoenix.PubSub.broadcast("run:" <> run_id, {:run_event, event})           │
│   → All subscribed clients receive event                                        │
│   → EventStore persists for replay                                              │
│                                                                                │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Protocol Details

### JSON-RPC 2.0 with Content-Length Framing

Code Puppy bridge-worker mode uses **JSON-RPC 2.0** over stdio with **Content-Length** HTTP-style framing for robust communication between Elixir and Python. In this mode stdout is reserved exclusively for framed protocol messages; human-facing banners, renderers, first-run config onboarding, version status, and other diagnostics must be skipped or sent somewhere other than stdout.

#### Framing Format

```
Content-Length: <bytes>\r\n
\r\n
<json_rpc_message>
```

#### Example Message Exchange

**Elixir → Python: Initialize**
```http
Content-Length: 72\r\n\r\n
{"jsonrpc":"2.0","method":"initialize","params":{"run_id":"run-abc123"}}
```

**Python → Elixir: Notification (Event)**
```http
Content-Length: 156\r\n\r\n
{
  "jsonrpc": "2.0",
  "method": "run.event",
  "params": {
    "type": "text",
    "run_id": "run-abc123",
    "session_id": "session-xyz789",
    "content": "Analyzing code structure...",
    "timestamp": 1713123456789
  }
}
```

**Elixir → Python: Request/Response**
```http
# Request:
Content-Length: 83\r\n\r\n
{"jsonrpc":"2.0","id":"req-1","method":"ping","params":{"timestamp":1713123456789}}

# Response:
Content-Length: 95\r\n\r\n
{"jsonrpc":"2.0","id":"req-1","result":{"success":true,"pong":true,"timestamp":1713123456.789}}
```

### Message Types

| Type | Direction | Purpose |
|------|-----------|---------|
| **Request** | Elixir → Python | Execute command, expect response |
| **Response** | Python → Elixir | Return result for a request |
| **Notification** | Bidirectional | Fire-and-forget event |

### Protocol Methods

#### Elixir → Python (Control)

| Method | Params | Description |
|--------|--------|-------------|
| `initialize` | `{run_id, elixir_pid}` | Worker setup |
| `run.start` | `{agent_name, prompt, session_id}` | Start execution |
| `run.cancel` | `{run_id}` | Soft cancel request |
| `run.provide_response` | `{prompt_id, response}` | User input delivery |
| `ping` | `{}` | Health check |
| `exit` | `{reason, timeout_ms}` | Graceful exit; flips the bridge controller out of its run loop |

#### Python → Elixir (Events)

| Method | Params | Description |
|--------|--------|-------------|
| `run.status` | `{status, run_id, session_id}` | State transition |
| `run.event` | `{type, payload, timestamp, ...}` | Streaming event |
| `run.text` | `{content, chunk, run_id}` | Text output |
| `run.tool_result` | `{tool_name, result, ...}` | Tool execution |
| `run.prompt` | `{prompt_id, question, ...}` | User input request |
| `run.completed` | `{result, token_usage, ...}` | Success completion |
| `run.failed` | `{error, stack_trace, ...}` | Error completion |

### JSON-RPC Error Codes

| Code | Meaning | When Used |
|------|---------|-----------|
| `-32700` | Parse Error | Invalid JSON received |
| `-32600` | Invalid Request | Not a valid JSON-RPC message |
| `-32601` | Method Not Found | Unknown method called |
| `-32602` | Invalid Params | Wrong parameters for method |
| `-32603` | Internal Error | Python exception |
| `-32000` to `-32099` | Server Error | Application-specific errors |

---

## 5. Deployment Modes

| Mode | Entry Point | Runtime | When to Use |
|------|-------------|---------|-------------|
| **CLI Interactive (default)** | `pup` (Burrito binary or escript) | Elixir-native | ✅ Default — local development, day-to-day coding |
| **CLI Prompt-only** | `pup -p "create a React component"` | Elixir-native | CI/CD, automation, scripting |
| **TUI Mode** | `pup` (TUI auto-launch) | Elixir-native (Owl) | Rich terminal interface |
| **Bridge Mode** (legacy) | `PUP_RUNTIME=python pup` | Elixir → Python bridge | Legacy compatibility; Python agent via JSON-RPC over stdio |
| **HTTP API** | `CodePuppyControlWeb` | Elixir (Phoenix) | External integrations, web dashboards |
| **WebSocket** | `ws://host/socket` | Elixir (Phoenix) | Real-time UIs, streaming responses |

### Mode Selection Logic (Elixir-Native)

```
Entry Point: pup (Elixir binary)
┌─────────────────────────────────────────────────────────┐
│                CodePuppyControl.CLI.run()               │
└──────────────────┬──────────────────────────────────────┘
                   │
         ┌─────────┴─────────┐
         │
    PUP_RUNTIME=python?  ◀── yes ──▶  Route to PythonWorker.Port (legacy bridge)
         │ no
         ▼
    args.prompt?  ◀── yes ──▶  execute_single_prompt()
         │ no
         ▼
    TUI available?  ◀── yes ──▶  Owl-based TUI
         │ no
         ▼
         REPL/interactive loop  ◀── default CLI loop
```

> **Note**: The legacy Python CLI (`code-puppy` or `python -m code_puppy`) still exists for
> backward compatibility but is not the default entry point. All new development should
> use the Elixir-native `pup` binary.

---

## 6. Technology Stack

| Layer | Technology (Default) | Purpose |
|-------|---------------------|---------|
| **Core Runtime** | **Elixir/OTP** (BEAM) | **✅ Default** — CLI, TUI, agents, LLM, tools, sessions |
| **CLI Binary** | Burrito (single-binary) or escript | Self-contained `pup` executable |
| **TUI** | Owl (Elixir) | Rich terminal interface |
| **LLM Provider** | `CodePuppyControl.ModelFactory` | Provider registry, HTTP streaming |
| **HTTP Client** | Finch / Mint (Elixir) | Async HTTP for LLM APIs |
| **Agent System** | Agent behaviours (Elixir) | Agent lifecycle, tool dispatch |
| **File Operations** | `FileOps` (Elixir) | list_files, grep, read/write |
| **Parsing** | `Parsing.Parser` (Elixir leex/yecc) | Syntax analysis (Elixir, Python, JS, TS, Rust) |
| **Config** | INI parser (Elixir) | `~/.code_puppy_ex/` settings |
| **Session Store** | Ecto + SQLite | State persistence |
| **Event Bus** | Phoenix.PubSub | Event broadcasting |
| **Web Server** | Phoenix + Cowboy | HTTP/WebSocket/Admin UI |
| **Scheduler** | Oban | Background job processing |
| **Plugin System** | `CodePuppyControl.Callbacks` | Hook-based (Elixir-native, with Python compat) |
| **MCP** | GenServer + Port | MCP server lifecycle |

### Python Bridge Dependencies (Optional / Legacy)

When `PUP_RUNTIME=python` is set, the Python worker requires the Python package dependencies and, in production bridge mode, a configured worker script (`PUP_PYTHON_WORKER_SCRIPT` unless supplied via app config/discovery):

```toml
[project.dependencies]
pydantic = ">=2.10"
pydantic-ai = ">=0.0.24"
httpx = ">=0.27"
rich = ">=13.9"
textual = ">=0.85"
```

> These dependencies and `PUP_PYTHON_WORKER_SCRIPT` are **only required** when running explicit legacy bridge mode.
> The default Elixir runtime has zero Python dependency and does not read a Python worker script.

---

## 7. Plugin Architecture

Code Puppy uses a **callback-based plugin system** for extensibility. The default runtime uses
`CodePuppyControl.Callbacks` (Elixir-native), with backward compatibility for legacy Python plugins
when `PUP_RUNTIME=python` bridge mode is active.

```
┌─────────────────────────────────────────────────────────────────┐
│                    PLUGIN ARCHITECTURE                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │    CodePuppyControl.Callbacks (Elixir-native)            │  │
│   │                                                          │  │
│   │   register_callback("startup", my_func)                 │  │
│   │   register_callback("shutdown", my_func)                │  │
│   │   register_callback("load_prompt", my_func)             │  │
│   │   ...                                                    │  │
│   └─────────────────────────────────────────────────────────┘  │
│                              │                                  │
│          ┌───────────────────┼───────────────────┐              │
│          ▼                   ▼                   ▼              │
│   ┌────────────┐     ┌────────────┐     ┌────────────┐        │
│   │ Built-in   │     │  Built-in  │     │   User     │        │
│   │ Elixir     │     │  Python    │     │  Plugins   │        │
│   │ Plugins    │     │  Plugins   │     │  (Elixir/  │        │
│   │            │     │  (legacy)  │     │   Python)  │        │
│   │• pack_par  │     │• fast_puppy│     │~/.code_    │        │
│   │            │     │ (status)   │     │            │        │
│   │• agent_trc │     │• file_ments│     │ puppy_ex/  │        │
│   │• agent_mem │     │• agent_skls│     │  plugins/  │        │
│   │• code_explr│     │• shell_safe│     │  or        │        │
│   │• loop_det  │     │• turbo_exe │     │~/.code_    │        │
│   │            │     │• ...       │     │  puppy/    │        │
│   └────────────┘     └────────────┘     └────────────┘        │
│                                                                 │
│   Discovery (Elixir-native):                                    │
│   ─────────────────────────────                                 │
│   1. Scan CodePuppyControl.Plugins.* (built-in Elixir)          │
│   2. Scan ~/.code_puppy_ex/plugins/*/register_callbacks.ex      │
│   3. For legacy Python compat: scan code_puppy/plugins/*/        │
│      register_callbacks.py (via PythonWorker bridge)            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Common Hook Points

| Hook | When | Use Case |
|------|------|----------|
| `startup` | App boot | Initialize resources |
| `shutdown` | Graceful exit | Cleanup, save state |
| `load_prompt` | Prompt assembly | Add custom instructions |
| `agent_run_start` | Before agent executes | Setup tracing |
| `agent_run_end` | After agent completes | Log results |
| `run_shell_command` | Before shell exec | Safety validation |
| `file_permission` | Before file op | Access control |
| `stream_event` | Response streaming | UI updates |

---

## Architecture Principles

1. **Elixir-Native by Default**: The `pup` binary runs all core operations without Python. Python is only needed for legacy bridge mode.
2. **BEAM Reliability**: OTP supervision trees, GenServers, and ETS provide fault tolerance and concurrency without manual lock management.
3. **Event-Driven**: PubSub pattern enables loose coupling between components.
4. **Plugin-First**: New features should prefer the hook-based plugin architecture over core modification.
5. **Zero-Copy Where Possible**: MessageBatch avoids repeated serialization via ETS caching.
6. **No Rust**: Pure Elixir + optional Python — simplified build, same performance via BEAM/OTP.

---

*Document generated for Code Puppy - woof! 🐕*
