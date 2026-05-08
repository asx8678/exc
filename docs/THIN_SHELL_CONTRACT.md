# Historical Thin Shell Contract: Python → Elixir Migration

> **Issue:** Thin Shell Contract  
> **Status:** Historical / superseded by the Elixir-native `pup` runtime. This document is preserved as migration context, not as the current target architecture. The current daily-driver path is `CodePuppyControl`; Python remains only for legacy PyPI compatibility, Python plugins/agents, and explicit bridge mode (`PUP_RUNTIME=python` / `--bridge-mode`).
> **Last Updated:** 2026-04-17  
> **Superseded Note Added:** 2026-05-05
> **Changes:** Fixed base_agent.py count (3,152 vs ~1,300), added command_line/ tier, documented all 34 bridge RPC methods, added "Uncategorized" section with 62K+ lines, corrected Rust counts (38 files, 119K lines)

---

## Historical Purpose

This document defined the **"thin shell"** — the minimal Python surface that was expected to remain after the Elixir migration completed. That is no longer the current end-state guidance. It answers historical planning questions:

1. **Why does Python remain?** — TUI rendering, CLI entry point, pydantic-ai agent orchestration
2. **What exactly stays in Python?** — Specific modules with justification
3. **What gets deleted?** — Everything ported to Elixir or redundant
4. **How do they communicate?** — The bridge contract
5. **Decision criteria** — How to determine if a module stays or goes

---

## End State Vision

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PYTHON (Thin Shell)                           │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────────────┐  │
│  │    CLI     │  │    TUI     │  │   pydantic-ai Agent Loop    │  │
│  │  (typer/   │  │ (Textual/  │  │  (BaseAgent + tool binding)  │  │
│  │  argparse) │  │   Rich)    │  │                             │  │
│  └──────┬─────┘  └──────┬─────┘  └──────────────┬──────────────┘  │
│         │               │                        │                  │
│         └───────────────┴────────────────────────┘                  │
│                              │                                       │
│                    ┌─────────┴──────────┐                          │
│                    │   Bridge Layer       │  ← JSON-RPC over stdio  │
│                    │   (elixir_bridge/)   │                          │
│                    └─────────┬──────────┘                          │
└──────────────────────────────┼──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     ELIXIR (All Runtime)                           │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────┐    │
│  │  Scheduler │  │  FileOps   │  │  Text Ops  │  │  Parse   │    │
│  │   (Oban)   │  │ (list/grep/│  │(diff/fuzzy/│  │ (Tree-   │    │
│  │            │  │  read)     │  │ replace)   │  │ sitter)  │    │
│  └────────────┘  └────────────┘  └────────────┘  └──────────┘    │
│                                                                    │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                   │
│  │  Message   │  │  Token     │  │  Registry  │                  │
│  │   Core     │  │  Estimate  │  │   (Phx)    │                  │
│  └────────────┘  └────────────┘  └────────────┘                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Retained Modules (The Thin Shell)

### Tier 1: Entry Points (Must Stay)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/__main__.py` | ~10 | Python package entry point. Unconditionally required. |
| `code_puppy/main.py` | ~20 | Re-export for `python -m code_puppy`. No logic. |
| `code_puppy/cli_runner.py` | ~200 | CLI argument parsing with **lazy imports** for fast `--help`. Argparse/typer require Python. |

### Tier 2: Application Bootstrap (Must Stay)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/app_runner.py` | ~400 | `AppRunner` class orchestrates startup: renderer selection, signal handling, plugin loading, DBOS init. Coordinates the thin shell. |
| `code_puppy/interactive_loop.py` | ~550 | REPL implementation with prompt_toolkit integration. User input handling is inherently Python-side. |
| `code_puppy/repl_session.py` | ~350 | Session persistence across restarts. Manages conversation history metadata and project context. |
| `code_puppy/prompt_runner.py` | ~200 | Executes prompts with attachment handling. Bridges TUI to agent layer. |

### Tier 3: TUI Layer (Must Stay - Rich/Textual)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/tui/app.py` | ~800 | Textual TUI main application. Terminal UI framework is Python-native. |
| `code_puppy/tui/screens/*.py` | ~200/ea | 20+ screen modules for settings, agents, MCP, etc. Rich UI components. |
| `code_puppy/tui/widgets/*.py` | ~300 total | Custom widgets (completion overlay, searchable lists). |
| `code_puppy/tui/message_bridge.py` | ~400 | Bridges MessageBus to Textual rendering. |
| `code_puppy/tui/theme.py` | ~150 | Theme configuration for Rich/Textual. |

### Tier 4: Agent Orchestration (Must Stay - pydantic-ai)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/agents/base_agent.py` | **3,152** | Core pydantic-ai agent loop. Tool binding, message history, streaming. The **heart** of the thin shell. |
| `code_puppy/agents/agent_prompt_mixin.py` | ~200 | System prompt assembly with plugin hooks. |
| `code_puppy/agents/agent_state.py` | ~250 | AgentRuntimeState for conversation persistence. |
| `code_puppy/agents/event_stream_handler.py` | ~600 | Streaming response handling. |
| `code_puppy/agents/agent_manager.py` | ~800 | Agent registry and discovery. |
| `code_puppy/agents/agent_code_puppy.py` | ~150 | Default agent implementation. |
| `code_puppy/agents/pack/*.py` | ~400 total | Pack sub-agents (Retriever, Shepherd, etc.). |

### Tier 5: Bridge Layer (Must Stay - Communication)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/plugins/elixir_bridge/__init__.py` | 616 | Client mode for Python → Elixir calls. `call_method()`, `is_connected()`. |
| `code_puppy/plugins/elixir_bridge/bridge_controller.py` | 1,353 | Bridge mode: dispatches JSON-RPC from Elixir to Python tools (34 handlers). |
| `code_puppy/plugins/elixir_bridge/wire_protocol.py` | 1,525 | JSON-RPC serialization, Content-Length framing, event emit. |
| `code_puppy/plugins/elixir_bridge/register_callbacks.py` | 358 | Bridge startup/shutdown hook registration. |
| `code_puppy/elixir_transport.py` | ~450 | Standalone Elixir transport for file operations (non-bridge mode). |
| `code_puppy/elixir_transport_helpers.py` | ~200 | Convenience functions for standalone transport. |

### Tier 6: Plugin System (Must Stay - Extension Point)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/callbacks.py` | ~800 | Hook registry: `register_callback()`, `on_startup()`, `on_shutdown()`, `pre_tool_call`, `post_tool_call`. |
| `code_puppy/plugins/__init__.py` | ~600 | Plugin loader with auto-discovery. |
| `code_puppy/plugins/*/register_callbacks.py` | ~50-300/ea | Individual plugin hooks. ~50 plugins, ~8KB total. |

### Tier 6b: command_line/ Package (Must Stay - CLI Layer)

| Module | Files | Lines | Justification |
|--------|-------|-------|---------------|
| `code_puppy/command_line/` | 58 | 17,143 | Complete CLI interaction layer — slash commands, menus, completions, attachments. Includes 20+ MCP commands, color menus, agent picker, model settings. TUI rendering requires Python. |

### Tier 7: Config & Tool Schema (Must Stay)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/config/` | ~2,900 | Config system (split by concern: loader, paths, models, agents, tui, limits, debug, cache, mcp). ADR-003 dual-home isolation. |
| `code_puppy/config_package/*.py` | ~1,200 | Pydantic-based config models and loaders. |
| `code_puppy/tool_schema.py` | 350 | Tool definition schemas for pydantic-ai. |

### Tier 8: Tool Binding (Must Stay - Interface Only)

| Module | Lines | Justification |
|--------|-------|---------------|
| `code_puppy/tools/agent_tools.py` | 1,059 | `invoke_agent_headless()`, agent execution orchestration. |
| `code_puppy/tools/common.py` | 1,326 | Tool utilities, context management, result formatting. |
| `code_puppy/tools/ask_user_question/*.py` | ~800 | TUI forms for user input. Inherently Python-side. |
| `code_puppy/tools/display.py` | ~100 | Display helpers for tool results. |
| `code_puppy/tools/command_runner.py` | 1,812 | Shell command execution with safety checks. |
| `code_puppy/tools/file_operations.py` | 1,029 | File operation interface layer (calls bridge). |

---

## Uncategorized — Migration Backlog

The following **62,000+ lines** across major modules are not yet classified as retained or deletable. These are **migration backlog items**, not release blockers — each will be classified as the Elixir migration progresses per-module. No architectural decisions are pending for the current release; these modules remain in Python and function as-is.

When a module reaches parity in Elixir, it should be reclassified as **Deletable** and a porting issue filed. Until then, the "Proposed Direction" column is advisory and subject to change.

### Infrastructure & Utilities

| Module | Files | Lines | Current Usage | Proposed Direction |
|--------|-------|-------|---------------|-------------------|
| `utils/` | 33 | 5,914 | File display, grep, path utils | Partial migration to Elixir `FileOps` |
| `messaging/` | 14 | 5,760 | MessageBus, event routing | Hybrid: keep local router, use Elixir EventBus for cross-process |
| `hook_engine/` | 8 | 1,326 | Hook lifecycle management | **Likely Retain** — core to Python plugin system |
| `compaction/` | 5 | 951 | Context compaction | **Migration backlog** — review against Elixir state management |
| `capability/` | 4 | 720 | Capability registration | **Likely Retain** — Python-side feature flags |
| `code_context/` | 3 | 683 | Code context extraction | Review against Elixir text processing |
| `routing/` | 9 | 447 | Request routing | **Likely Delete** — Elixir has native routing |

### Browser & MCP

| Module | Files | Lines | Current Usage | Proposed Direction |
|--------|-------|-------|---------------|-------------------|
| `tools/browser/` | 13 | 4,750 | Browser automation, Playwright | **DROP-V1** — No mature Elixir browser automation; revisit post-v1 |
| `mcp_/` | 19 | 8,158 | MCP server management | **Under Review** — Elixir has native MCP |

### Agents Beyond Base

| Module | Files | Lines | Current Usage | Proposed Direction |
|--------|-------|-------|---------------|-------------------|
| `agents/` (excl. base) | 33 | 7,999 | Pack sub-agents, specializations | Review per-agent: keep pydantic-ai, migrate others |

### Scheduler & API

| Module | Files | Lines | Current Usage | Proposed Direction |
|--------|-------|-------|---------------|-------------------|
| `scheduler/` | 9 | 840 | Job scheduling | **Likely Delete** — Elixir Oban replaces |
| `api/` | 12 | 2,296 | REST API layer | **Under Review** — May migrate to Phoenix |

### Root-Level Modules (62 files, 22,374 lines)

Key unclassified top-level modules:

| Module | Lines | Notes |
|--------|-------|-------|
| `adaptive_rate_limiter.py` | 1,155 | Has bridge methods — keep until fully migrated |
| `concurrency_limits.py` | 800 | Has bridge methods — coordination with Elixir |
| `elixir_transport.py` | 572 | **Retained** — standalone transport (already in Tier 5) |
| `model_factory.py` | 1,004 | Model instantiation — review |
| `pydantic_patches.py` | 534 | Pydantic compatibility — **Retain** |
| `session_storage.py` | 748 | Session persistence — review against Elixir |
| `resilience.py` | 652 | Retry/circuit logic — review |
| `workflow_state.py` | 400 | State management — review |
| `request_cache.py` | 660 | Caching layer — review |
| `token_ledger.py` | 284 | Token accounting — review |
| `staged_changes.py` | 1,000 | Git staging — review |
| `security.py` | 518 | Security policies — **Likely Retain** |
| `permission_decision.py` | 100 | Permission system — **Likely Retain** |
| `chatgpt_codex_client.py` | 462 | Codex client — **Likely Retain** |
| `claude_cache_client.py` | 1,068 | Claude caching — **Likely Retain** |
| `reflection.py` | 180 | Agent reflection — review |

### Plugins (excluding elixir_bridge)

46 plugin subdirectories totaling ~38,000 lines require individual review:

| Plugin Category | Examples | Direction |
|-----------------|----------|-----------|
| Bridge integrations | `fast_puppy/`, `turbo_indexer_bridge.py` | Historical review bucket; current `fast_puppy` is status-only |
| UI enhancements | `theme_switcher/`, `colors_menu/` | **Retain** |
| Git workflow | `git_auto_commit/`, `shell_safety/` | Review |
| Agent features | `agent_memory/`, `agent_trace/`, `loop_detection/` | Review |
| System integration | `ollama_setup/`, `shell_safety/` | Review |

---

## Quick Stats Reconciliation

| Category | Files | LOC | % of Total |
|----------|-------|-----|------------|
| **Retained** (Tiers 1-8) | ~110 | ~35,000 | 24% |
| **Deletable** (Migrated/To-Migrate) | ~95 | ~28,000 | 19% |
| **Uncategorized — Pending** | ~255 | ~82,000 | 57% |
| **Rust** | 38 | 119,134 | — |
| **Total Python** | 523 | 144,818 | 100% |

### Retained Breakdown
| Tier | Modules | Approx LOC |
|------|---------|--------------|
| CLI/Entry | `__main__`, `cli_runner`, `main` | 250 |
| Bootstrap | `app_runner`, `interactive_loop`, `repl_session`, `prompt_runner` | 1,700 |
| TUI | `tui/` (32 files) | 8,109 |
| Agent Core | `agents/base_agent.py`, orchestration | 12,000 |
| Bridge | `elixir_bridge/`, `elixir_transport` | 4,400 |
| Plugins | Core + callbacks | 2,000 |
| Config | `config.py`, `config_package/` | 4,000 |
| Tools (interface) | `tools/agent_tools`, `common`, `ask_user_question/` | 4,000 |
| command_line | 58 files | 17,143 |

**Note:** The 43% unclassified figure from the shepherd review refers to the gap between ~35K retained and the full 144K LOC. The categorized "retained" and "deletable" sections only account for ~46% of the codebase. The remaining 57% is **migration backlog** — functional Python code that will be classified as the Elixir migration progresses. These modules are not release blockers.

---

## Deletable Modules (Ported to Elixir)

### Already Migrated ✅

| Category | Python Module | Elixir Replacement |
|----------|---------------|-------------------|
| **File Operations** | `tools/file_operations.py` | `FileOps` (Elixir) |
| **File List** | `utils/file_display.py` (partial) | `FileOps.Lister` |
| **Grep** | `utils/` grep functions | `FileOps.Grep` |
| **Scheduler** | `scheduler/*.py` | `Scheduler` (Oban) |
| **Repo Indexer** | `plugins/repo_compass/` | `Indexer.RepoCompass` |
| **Text Processing** | | |
| ├─ Content Prep | Rust `content_prep.rs` | `Text.ContentPrep` |
| ├─ Path Classify | Rust `path_classify.rs` | `FileOps.PathClassifier` |
| ├─ Line Numbers | Rust `line_numbers.rs` | `Text.LineNumbers` |
| ├─ Unified Diff | Rust `unified_diff.rs` | `Text.Diff` |
| ├─ Fuzzy Match | Rust `fuzzy_match.rs` | `Text.FuzzyMatch` |
| ├─ Replace Engine | Rust `replace_engine.rs` | `Text.ReplaceEngine` |
| └─ Hashline | Rust `hashline.rs` | `HashlineNif` (Elixir NIF) |
| **API Layer** | `api/*.py` | May be replaced by Elixir Phoenix controllers |
| **MCP Python** | `mcp_/*.py` | Elixir has native MCP implementation |
| **Scheduler CLI** | `scheduler/cli.py` | Elixir provides CLI |
| **Legacy Tools** | `tools/file_modifications.py` | Functionality moved to Elixir Text ops |
| **Turbo Executor** | `plugins/turbo_executor/` | Orchestration moved to Elixir |
| **Rate Limiter** | `adaptive_rate_limiter.py` | Can migrate to Elixir |
| **Message Bus** | `messaging/bus.py` | Can use Elixir EventBus |
| **Concurrency** | `concurrency_limits.py` | Elixir has native supervision |

---

## Bridge Contract: Python ↔ Elixir

### Transport Layer

```python
# Python side (elixir_bridge/__init__.py)
call_method(method: str, params: dict, timeout: float = 30.0) -> dict
is_connected() -> bool
notify_elixir_event(event_type: str, payload: dict, run_id: str | None) -> None
```

### Communication Protocol

- **Format:** JSON-RPC 2.0
- **Framing:** Content-Length headers for stdio
- **Transport:** Stdio Port (bridge mode) or Unix socket (standalone)
- **Bidirectional:** Python can call Elixir; Elixir can call Python

### RPC Methods (Elixir → Python - Bridge Controller)

These 34 methods are registered in `bridge_controller.py` handlers dict — Elixir calls these to invoke Python functionality:

#### Core Lifecycle (4 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `initialize` | Initialize bridge | `capabilities`, `config` |
| `exit` | Shutdown bridge | `reason`, `timeout_ms` |
| `get_status` | Bridge status | — |
| `ping` | Health check | — |

#### Agent Execution (3 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `run.start` | Start agent run | `agent_name`, `prompt`, `session_id`, `run_id` |
| `run.cancel` | Cancel active run | `run_id`, `reason` |
| `invoke_agent` | Run agent directly | `agent_name`, `prompt`, `session_id` |

#### Shell & File Operations (5 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `run_shell` | Execute shell command | `command`, `cwd`, `timeout` |
| `file_list` | List directory | `directory`, `recursive` |
| `file_read` | Read file | `path`, `start_line`, `num_lines` |
| `file_write` | Write file | `path`, `content` |
| `grep_search` | Search files | `search_string`, `directory` |

#### Concurrency Control (3 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `concurrency.acquire` | Acquire slot | `type` (file_ops/api_calls/tool_calls) |
| `concurrency.release` | Release slot | `type` |
| `concurrency.status` | Get status | — |

#### Run Limiter (4 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `run_limiter.acquire` | Acquire run slot | `timeout` |
| `run_limiter.release` | Release run slot | — |
| `run_limiter.status` | Get limiter status | — |
| `run_limiter.set_limit` | Update limit | `limit` |

#### MCP Bridge (6 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `mcp.register` | Register MCP server | `name`, `command`, `args`, `env`, `opts` |
| `mcp.unregister` | Unregister server | `server_id` |
| `mcp.list` | List servers | — |
| `mcp.status` | Server status | `server_id` |
| `mcp.call_tool` | Call tool (limited) | `server_id`, `method`, `params` |
| `mcp.health_check` | Health check all | — |

#### EventBus (1 method)
| Method | Purpose | Params |
|--------|---------|--------|
| `eventbus.event` | Route Elixir→Python events | `topic`, `event_type`, `payload` |

#### Rate Limiter (4 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `rate_limiter.record_limit` | Record 429 | `model_name` |
| `rate_limiter.record_success` | Record success | `model_name` |
| `rate_limiter.get_limit` | Get limit | `model_name` |
| `rate_limiter.circuit_status` | Circuit state | `model_name` |

#### Agent Manager (4 methods)
| Method | Purpose | Params |
|--------|---------|--------|
| `agent_manager.register` | Register agent | `agent_name`, `agent_info` |
| `agent_manager.list` | List agents | — |
| `agent_manager.get_current` | Get current agent | — |
| `agent_manager.set_current` | Set current agent | `agent_name` |

**Total: 34 registered RPC methods** (verified via `bridge_controller.py` handlers dict)

### RPC Methods (Python → Elixir)

| Method | Purpose | Params | Returns |
|--------|---------|--------|---------|
| `file_list` | List directory | `directory`, `recursive`, `ignore_patterns` | `files[]` |
| `file_read` | Read file | `path`, `start_line`, `num_lines` | `content`, `truncated` |
| `file_read_batch` | Read multiple files | `paths[]` | `files[]` |
| `grep_search` | Search files | `pattern`, `directory`, `max_matches` | `matches[]` |
| `text_diff` | Unified diff | `old_content`, `new_content` | `diff` |
| `text_fuzzy_match` | Fuzzy search | `pattern`, `choices[]` | `matches[]` |
| `text_replace` | Replace in content | `content`, `old_str`, `new_str` | `content`, `replaced` |
| `parse_extract_symbols` | Symbol extraction | `code`, `language` | `symbols[]` |
| `parse_diagnostics` | Syntax errors | `code`, `language` | `diagnostics[]` |
| `scheduler.schedule` | Schedule job | `task_id`, `cron`, `command` | `job_id` |

### Error Handling

```python
# Bridge errors map to Python exceptions
ElixirTransportError        # Connection/transport issues
WireMethodError            # JSON-RPC protocol errors
TimeoutError               # Elixir timeout (fallback to Python)
RuntimeError               # Elixir returned error response
```

---

## Decision Criteria: Stay vs. Go

### Module Stays in Python If:

| Criterion | Examples |
|-----------|----------|
| **User interface** | TUI screens, REPL input, clipboard handling |
| **pydantic-ai integration** | Agent loop, tool binding, streaming |
| **CLI entry point** | Argument parsing, `--help`, `--version` |
| **Plugin callbacks** | Hook registration, custom commands |
| **Python-specific libs** | prompt_toolkit, Textual, Rich |
| **Bridge coordination** | Message marshaling, protocol handling |

### Module Migrates to Elixir If:

| Criterion | Examples |
|-----------|----------|
| **Performance-critical I/O** | File operations, directory traversal |
| **Background scheduling** | Cron jobs, task queue, Oban |
| **Text processing** | Diff, fuzzy match, EOL normalization |
| **State management** | Session registry, run tracking |
| **Parse operations** | Tree-sitter routing (via NIF) |
| **Concurrency control** | Rate limiting, semaphore coordination |

### Special Cases:

| Module | Decision | Rationale |
|--------|----------|-----------|
| `turbo_parse` | **Migrated** | Tree-sitter now handled via `turbo_parse_nif` Elixir NIF. Decision resolved: Rust completely removed in favor of Elixir. |
| `messaging/bus.py` | **Conditional** | MessageBus may stay as local event router even with Elixir EventBus for intra-Python events. Hybrid approach likely. |
| `plugins/*/register_callbacks.py` | **Historical stay** | Historical note: at the time, the plugin contract was Python-led. Current default runtime uses `CodePuppyControl.Callbacks`; Python plugins are compatibility/bridge-only. |

---

## Phase 6 End State: File Count Target

### Current State (2026-04-17) — Verified Counts

| Component | Files | Lines | Notes |
|-----------|-------|-------|-------|
| **Python files** | 523 | 144,818 | Measured via `find` |
| **Rust files** | 0 | 0 | **Removed** — All Rust code migrated to Elixir (2026-Q2) |
| **Elixir files** | ~121 | — | Approximate count |

> **Historical Context:** The original Rust components (`code_puppy_core/`, `turbo_parse/`, `turbo_parse_core/`) were completely removed in favor of Elixir NIFs. The `turbo_parse/` directory contained ~112K lines largely from generated tree-sitter bindings.

### Phase 6 Target (2026-Q3)

| Layer | Files | LOC (est.) | Notes |
|-------|-------|-----------|-------|
| Python Thin Shell | ~110-130 | ~35,000 | CLI, TUI, agent loop, bridge, command_line/ |
| Elixir Runtime | ~150+ | ~40,000 | All services, NIFs |


---

## Migration Verification Checklist

Before declaring a module "migrated to Elixir":

- [ ] Elixir implementation passes all Python test cases
- [ ] Bridge RPC contract documented
- [ ] Python fallback removed (or disabled by default)
- [ ] Performance parity or improvement demonstrated
- [ ] Error handling matches or exceeds Python behavior
- [ ] Metrics/logging integration verified

---

## Appendix: Directory Structure (End State)

```
code_puppy/
├── __init__.py              # Package exports
├── __main__.py              # Entry point
├── main.py                  # Re-export
├── cli_runner.py            # CLI args with lazy imports
├── app_runner.py            # Application bootstrap
├── interactive_loop.py      # REPL implementation
├── prompt_runner.py         # Prompt execution
├── repl_session.py          # Session persistence
├── config.py                # Configuration system
├── tool_schema.py           # Tool definitions
├── callbacks.py             # Hook registry
│
├── agents/                  # pydantic-ai orchestration (~11K lines total)
│   ├── __init__.py
│   ├── base_agent.py        # Core agent loop (3,152 lines — heart of thin shell)
│   ├── agent_manager.py     # Agent registry (~800 lines)
│   ├── agent_state.py         # Runtime state (~250 lines)
│   ├── agent_prompt_mixin.py # Prompt assembly (~200 lines)
│   ├── agent_code_puppy.py  # Default agent (~150 lines)
│   ├── event_stream_handler.py # Streaming (~600 lines)
│   └── pack/                # Sub-agents (Retriever, Shepherd, etc.)
│
├── command_line/            # CLI components (58 files, 17,143 lines)
│   ├── command_handler.py   # Slash command routing
│   ├── prompt_toolkit_completion.py
│   ├── core_commands.py     # Core slash commands
│   ├── agent_menu.py        # TUI agent selection
│   ├── model_settings_menu.py
│   ├── mcp/                 # MCP commands (15+ files)
│   ├── attachments.py
│   └── ... (54 more files)
│
├── tools/                   # Tool interface layer (37 files, 15,634 lines)
│   ├── agent_tools.py       # Agent invocation (1,059 lines)
│   ├── common.py            # Tool utilities (1,326 lines)
│   ├── command_runner.py    # Shell execution (1,812 lines)
│   ├── file_operations.py   # File ops interface (1,029 lines)
│   ├── ask_user_question/   # TUI forms (~800 lines)
│   ├── browser/             # Browser automation (13 files, 4,750 lines)
│   └── display.py
│
├── tui/                     # Textual interface
│   ├── app.py               # Main TUI app
│   ├── screens/             # 20+ screen modules
│   ├── widgets/             # Custom components
│   └── theme.py
│
├── plugins/                 # Plugin system (49 subdirs, ~42K lines)
│   ├── __init__.py          # Loader (~600 lines)
│   ├── callbacks.py         # Hook registry (~800 lines)
│   ├── elixir_bridge/       # Bridge layer (4 files, 3,852 lines)
│   │   ├── __init__.py      # Client mode (616 lines)
│   │   ├── bridge_controller.py  # 34 RPC handlers (1,353 lines)
│   │   ├── wire_protocol.py # JSON-RPC framing (1,525 lines)
│   │   └── register_callbacks.py # Bridge hooks (358 lines)
│   ├── pack_parallelism/    # Run limiter
│   ├── fast_puppy/          # Historical acceleration/status stub
│   ├── file_mentions/         # @file support
│   └── */register_callbacks.py  # ~46 more plugin hooks
│
├── elixir_transport.py      # Standalone transport
└── config_package/          # Pydantic config models
```

---

## Related Documents

| Document | Purpose |
|----------|---------|
| `ARCHITECTURE.md` | Overall system architecture |
| `docs/protocol/BRIDGE_PROTOCOL_V1.md` | RPC contract specification |
| `docs/protocol/ELIXIR_STANDALONE_TRANSPORT.md` | Transport details |
| `docs/adr/ADR-001-elixir-python-worker-protocol.md` | Design rationale |

---

*Generated by Code Puppy 🐕*
