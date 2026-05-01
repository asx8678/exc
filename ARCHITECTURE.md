# 🐕 Code Puppy Architecture

> **Note:** As of Phase H cutover, Code Puppy runs on **Elixir only**.
> The Python codebase has been removed. See ADR-004 for migration history.

## High-Level System Architecture

Code Puppy runs entirely on the **Elixir/BEAM runtime** with OTP supervision trees for fault tolerance and concurrency.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              CODE PUPPY CONTROL                                │
│                         (Elixir/BEAM + OTP)                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                           INTERFACE LAYER                                 │  │
│  ├─────────────┬──────────────┬─────────────────┬───────────────────────────┤  │
│  │   CLI       │   API        │   Web Terminal  │   Plugin Commands         │  │
│  │  (TTY)      │ (WebSocket) │   (WebSocket)   │   (/slash)                │  │
│  └─────────────┴──────────────┴─────────────────┴───────────────────────────┘  │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         AGENT SYSTEM                                       │  │
│  ├─────────────┬──────────────┬─────────────────┬───────────────────────────┤  │
│  │ Agent       │ Agent        │ Pack Leader     │ Agent Runtime State       │  │
│  │ Manager     │ Registry     │ (Parallelism)   │ (History/Context)         │  │
│  └─────────────┴──────────────┴─────────────────┴───────────────────────────┘  │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         CORE SERVICES                                      │  │
│  ├─────────────┬──────────────┬─────────────────┬───────────────────────────┤  │
│  │ File        │ Parse        │ Message         │ Session                   │  │
│  │ Service     │ Service      │ Processor       │ Manager                   │  │
│  │ (list/read/ │ (Tree-sitter)│ (prune/hash)    │ (serialize/store)         │  │
│  │  grep)      │              │                 │                           │  │
│  └─────────────┴──────────────┴─────────────────┴───────────────────────────┘  │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         SCHEDULER & STORAGE                                 │  │
│  ├──────────────────────┬────────────────────┬───────────────────────────────┤  │
│  │ Oban Scheduler       │ DBOS State         │ Plugin System                │  │
│  │ (Job Queue)          │ (Checkpoints)      │ (Callback Hooks)             │  │
│  └──────────────────────┴────────────────────┴───────────────────────────────┘  │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         MCP & SECURITY                                     │  │
│  ├──────────────────────┬────────────────────┬───────────────────────────────┤  │
│  │ MCP Manager          │ Circuit Breaker    │ Command Whitelist             │  │
│  │ (Server Lifecycle)   │ (Fault Isolation)  │ (Injection Detection)         │  │
│  └──────────────────────┴────────────────────┴───────────────────────────────┘  │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         MODEL LAYER                                        │  │
│  ├─────────────┬──────────────┬─────────────────┬───────────────────────────┤  │
│  │ Model       │ Rate         │ Token Ledger    │ Model Switching           │  │
│  │ Registry    │ Limiter      │ (Tracking)      │ (Fallback Chain)          │  │
│  └─────────────┴──────────────┴─────────────────┴───────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Key Components:**

| Component | Description |
|-----------|-------------|
| **CodePuppyControl** | Main OTP application — supervision tree, GenServers, ETS tables |
| **Agent System** | Agent registry, lifecycle management, pack parallelism (max 8 agents) |
| **File Service** | High-performance file operations (list, read, grep) via Elixir streams |
| **Parse Service** | Tree-sitter based code parsing for multiple languages |
| **Message Processor** | Message serialization, hashing, and pruning for context management |
| **Session Manager** | MessagePack-based session serialization with full audit trails |
| **Oban Scheduler** | Distributed job queue for background task processing |
| **Plugin System** | Hook-based callback architecture for extensibility |
| **Model Registry** | LLM provider management with rate limiting and fallback chains |

## Data Flow Example: Agent Execution

```
User Input
    │
    ▼
┌──────────────┐
│  CLI/WS      │ ──► Parses input, routes to agent
└──────┬───────┘
       │
       ▼
┌──────────────┐
│AgentManager  │ ──► Discovers/selects agent
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Agent Gen-  │ ──► Loads system prompt
│  Server      │ ──► Loads message history
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Model Call   │ ──► LLM inference (GenServer)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Response     │ ──► Text or tool calls
└──────┬───────┘
       │
       ├───────────────────────┐
       │ (if text)             │ (if tool call)
       ▼                       ▼
┌──────────┐           ┌──────────────┐
│ Response │           │ Tool Router  │
│ to User  │           └──────┬───────┘
└──────────┘                  │
                              ├─────────────┬─────────────┐
                              │             │             │
                              ▼             ▼             ▼
                        ┌─────────┐   ┌──────────┐  ┌──────────┐
                        │File Ops │   │ Subagent │  │  Shell   │
                        │(Elixir) │   │(Pack Ldr)│  │(Safety)  │
                        └────┬────┘   └────┬─────┘  └────┬─────┘
                             │             │             │
                             └─────────────┴─────────────┘
                                           │
                                           ▼
                                    ┌──────────────┐
                                    │ Tool Results │
                                    └──────┬───────┘
                                           │
                                           ▼
                                    (Back to Agent)
```

## Key Architectural Decisions

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Runtime** | Pure Elixir/BEAM | Full OTP supervision, fault tolerance, concurrency |
| **Plugin System** | Hook-based callbacks | Hot-swappable, zero core modification |
| **Agent Concurrency** | Pack Leader with MAX=8 | Prevents resource exhaustion |
| **Model Routing** | Adaptive rate limiting | Protects against rate limit storms |
| **MCP Security** | Circuit breaker + whitelist | Defense in depth for external tools |
| **State Mgmt** | GenServer state isolation | OTP-compliant, testable, resettable |

## Class Hierarchy (Simplified)

```
CodePuppyControl.Application (OTP)
├── CodePuppyControl.Supervisor
│   ├── CodePuppyControl.Agent.Supervisor
│   │   ├── CodePuppyControl.Agent.Manager (GenServer)
│   │   ├── CodePuppyControl.Agent.Registry (ETS)
│   │   └── CodePuppyControl.Agent.PackLeader (GenServer)
│   ├── CodePuppyControl.File.Service (GenServer)
│   ├── CodePuppyControl.Parse.Service (GenServer)
│   ├── CodePuppyControl.Message.Processor (GenServer)
│   ├── CodePuppyControl.Session.Manager (GenServer)
│   ├── CodePuppyControl.Scheduler (Oban)
│   ├── CodePuppyControl.MCP.Manager (GenServer)
│   ├── CodePuppyControl.Model.Registry (ETS)
│   └── CodePuppyControl.Plugin.Loader
└── CodePuppyControl.Web.Endpoint (Phoenix/WebSock)
```

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

*Code Puppy 🐕 — pure Elixir, no Python. Built on BEAM.*
