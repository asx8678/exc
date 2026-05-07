# 🐕 Code Puppy Architecture

## High-Level System Architecture

> Code Puppy's runtime is **Elixir-native** (`CodePuppyControl` on BEAM/OTP).
> All core operations — agent execution, LLM, file ops, parsing, session state,
> plugins, TUI — run on the BEAM. No separate Python runtime is required.
>
> **ADR-005 boundary**: The Elixir runtime includes BEAM-native Python source
> *parsing* (lexer/parser via leex/yecc) for code analysis. This is parser data
> support, not Python runtime or product support.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         USER INTERFACE LAYER                                       │
├────────────────┬────────────────┬─────────────────┬──────────────────────────────┤
│   CLI (TTY)    │   TUI (Owl)    │   Web Terminal   │   Plugin Commands           │
│  (Elixir)      │  (Elixir)      │   (LiveView WS)  │   (/slash — Elixir)         │
└──────┬─────────┴───────┬────────┴────────┬────────┴──────────────┬───────────────┘
       │                 │                 │                       │
       └─────────────────┴─────────────────┴───────────────────────┘
                              │
                    ┌─────────┴────────────────────────────────────┐
                    │   ELIXIR CLI / RUNNER (pup binary)           │
                    │   (Burrito single-binary or escript)         │
                    └─────────┬────────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────────────────────┐
         │                    │                                    │
┌────────▼────────┐  ┌────────▼────────┐  ┌───────────────────────▼────┐
│ CONFIG SYSTEM   │  │ CALLBACK SYSTEM │  │  PLUGIN LOADER (Elixir)    │
│ (pup-ex.ini)    │  │  (CodePuppy     │  │  (Auto-discover Elixir     │
│                 │  │   Control.      │  │   plugins)                 │
│                 │  │   Callbacks)    │  │                            │
└────────┬────────┘  └────────┬────────┘  └────────────────────────────┘
         │                    │
         └────────────────────┘
                              │
                    ┌─────────┴────────────────────────────────────┐
                    │   AGENT MANAGER (GenServer + Registry)       │
                    │  (Agent Registry, Session Cache)             │
                    └─────────┬────────────────────────────────────┘
                              │
    ┌─────────────────────────┼────────────────────────────────────┐
    │                         │                                    │
┌───▼────────────────┐  ┌────▼──────────────┐  ┌──────────────────▼─────┐
│ AGENT BEHAVIOUR    │  │ AGENT RUNTIME      │  │   PACK LEADER          │
│ (Elixir behaviours)│  │ STATE (GenServer)  │  │(Parallelism Ctrl)      │
│                    │  │ (History/Ctx/ETS)  │  │   MAX=8 agents         │
└───┬────────────────┘  └────────────────────┘  └────────────────────────┘
    │
    │  ┌─────────────────────────────────────────────────────────────────┐
    │  │                    AGENT IMPLEMENTATIONS (Elixir)                │
    │  ├─────────────┬─────────────┬─────────────┬───────────────────────┤
    │  │ CodePuppy   │  CodeReviewer│ Security    │ PythonPro             │
    │  │  (Default)  │   (PR rev)   │  Auditor    │  (Code gen)           │
    │  ├─────────────┼─────────────┼─────────────┼───────────────────────┤
    │  │  TerminalQA │  TurboExec   │  CodeScout   │   QA Kitten          │
    │  │  (Q&A)      │  (Batch ops) │ (Explorer)  │  (Test help)          │
    │  └─────────────┴─────────────┴─────────────┴───────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                      LLM / MODEL LAYER (Elixir)                                │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌─────────────┐  │
│  │ Provider       │  │Rate Limiter    │  │Token Ledger    │  │ Model       │  │
│  │ Registry       │  │(GenServer+ETS) │  │(ETS Cache)     │  │ Switching   │  │
│  │ (GenServer)    │  │                │  │                │  │ (fallback)  │  │
│  └──────┬─────────┘  └───────┬────────┘  └───────┬────────┘  └──────┬──────┘  │
│         │                   │                    │                  │         │
│         └───────────────────┴────────────────────┴──────────────────┘         │
│                              │                                                │
│         ┌────────────────────┴───────────────────┐                            │
│         ▼                                        ▼                            │
│  ┌──────────────────┐              ┌──────────────────────────┐               │
│  │   HTTP Client    │              │   Streaming Protocol     │               │
│  │   (Elixir-native)│              │   (SSE/chunk handling)   │               │
│  └────────┬─────────┘              └────────────┬─────────────┘               │
│           │                                      │                            │
│  ┌────────▼──────────────────────────────────────▼──────────┐                │
│  │   Providers: Anthropic, OpenAI, Google, etc.             │                │
│  └───────────────────────────────────────────────────────────┘                │
└──────────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                            TOOL LAYER (Elixir)                                │
├────────────────┬────────────────┬────────────────┬───────────────────────────┤
│  FILE OPS      │  EXECUTION     │  AGENT OPS     │   USER INTERACTION        │
├────────────────┼────────────────┼────────────────┼───────────────────────────┤
│ • list_files   │ • run_shell    │ • invoke_agent │  • ask_user_question      │
│ • read_file    │   _command     │ • list_agents  │    (TUI forms)            │
│ • grep         │ • command      │                │                           │
│ • replace_in_  │   _runner      │                │                           │
│   file         │                │                │                           │
│ • create_file  │                │                │                           │
│ • delete_*     │                │                │                           │
└────────┬───────┴────────┬───────┴────────┬───────┴───────────────┬───────────┘
         │              │                │                       │
         └──────────────┴────────────────┴───────────────────────┘
                              │
                    ┌─────────┴──────────────────────────────────┐
                    │   ELIXIR OTP RUNTIME (Core)                │
                    │   (GenServers, ETS, Supervision Trees)     │
                    └─────────┬──────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
┌────────▼────────┐  ┌────────▼────────┐  ┌────────▼────────┐
│  FILE SERVICE   │  │  PARSE SERVICE  │  │  SCHEDULER      │
│ (FileOps)       │  │ (leex/yecc     │  │ (Oban Job Queue)│
│                 │  │  parsers)      │  │                 │
└─────────────────┘  └─────────────────┘  └─────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              MCP LAYER                                         │
├────────────────────────┬────────────────────────┬────────────────────────────┤
│    MCP MANAGER         │      CIRCUIT BREAKER   │      SECURITY LAYER        │
│  (DynamicSupervisor)   │    (Fault isolation)   │    (Command whitelist)     │
│                        │                        │    (Injection detect)      │
└────────────────────────┴────────────────────────┴────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                           PLUGIN ECOSYSTEM                                     │
├────────────────────┬────────────────────┬────────────────────────────────────┤
│   CORE PLUGINS     │   AUTH PLUGINS     │     FEATURE PLUGINS                  │
├────────────────────┼────────────────────┼────────────────────────────────────┤
│ • fast_puppy       │ • claude_code_oauth│ • agent_skills (Skill install)       │
│   (status stub)    │ • chatgpt_oauth    │ • turbo_executor (Batch ops)         │
│ • file_mentions    │                    │ • shell_safety (Cmd filter)          │
│   (@file support)  │                    │ • agent_trace (Analytics)            │
│ • repo_compass     │                    │ • agent_memory (Persistence)         │
│   (Repo mapping)   │                    │ • code_explorer (Nav)                │
│ • pack_parallelism │                    │ • loop_detection                     │
│   (Limits)         │                    │                                      │
└────────────────────┴────────────────────┴────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                            STORAGE LAYER                                       │
├────────────────────┬────────────────────┬────────────────────────────────────┤
│   SESSION STORAGE  │   PERSISTENCE      │      STATE MANAGEMENT                │
│ (Ecto/SQLite)      │  (checkpoints)     │    (GenServer + ETS)               │
└────────────────────┴────────────────────┴────────────────────────────────────┘
```

## Data Flow Example: Agent Execution

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

## Key Architectural Decisions

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Plugin System** | Hook-based callbacks (Elixir `PluginBehaviour`) | Hot-swappable, zero core modification |
| **Runtime** | Elixir-native (only path) | BEAM/OTP provides concurrency, fault tolerance, hot code reload |
| **Agent Concurrency** | Pack Leader with MAX=8 | Prevents resource exhaustion |
| **Model Routing** | Adaptive rate limiting (GenServer + ETS) | Protects against rate limit storms |
| **MCP Security** | Circuit breaker + whitelist | Defense in depth for external tools |
| **State Mgmt** | GenServer + ETS | Thread-safe (BEAM), testable, resettable |

## Agent Hierarchy (Elixir-Native)

```
AgentBehaviour (Elixir behaviour)
├── AgentRuntimeState (GenServer + ETS)
│
├── CodePuppyAgent
├── CodeReviewerAgent
├── SecurityAuditorAgent
├── PythonProgrammerAgent
├── TerminalQAAgent
├── TurboExecutorAgent
├── CodeScoutAgent
├── QAKittenAgent
├── HeliosAgent
├── CreatorAgent
│
└── Pack sub-agents
    ├── Retriever (search)
    ├── Retriever (file find)
    ├── Shepherd (delegation)
    ├── Terrier (grep)
    └── Watchdog (monitoring)
```

> **Historical note**: Agents were originally Python `BaseAgent (ABC)` classes.
> They have been fully ported to Elixir behaviours under `CodePuppyControl.Agents`.
> The Python agent source tree has been removed from the project.

## Hook Phases (Callback System)

```
startup ──► agent_run_start ──► pre_tool_call ──► [TOOL EXEC] ──► post_tool_call
                                                            │
                        invoke_agent ◄────────────────────────┘
                            │
                            ▼
                    subagent_stream_handler
                            │
                    agent_run_end ──► shutdown
```

---

*Generated by Code Puppy 🐕 on a rainy weekend*
