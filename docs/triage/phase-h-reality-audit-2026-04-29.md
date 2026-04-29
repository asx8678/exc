# Phase H Reality Audit

**Issue:** code_puppy-djs.1 (Phase H reality audit — FIRST)
**Date:** 2026-04-29
**Auditor:** pack-leader-ee29a4 (code-puppy-66c3cf)
**Historical mapping:** code_puppy-3f9.4
**Status:** ✅ COMPLETE

## Executive Summary

**Key Finding:** Phases A–G are **complete and merged**. Elixir has comprehensive coverage across all capability domains — 79K LoC in 868+ source files with 362 test files. However, **Phase H (cutover) has three blocking gaps** before rollout can begin:

1. **No feature-flag system** — ADR-004 specifies `flags.json` with per-capability toggles; neither Python nor Elixir implements this. Only `PUP_RUNTIME` env var and `enable_elixir_message_shadow_mode` config toggle exist.
2. **No runtime selector / dual-run router** — ADR-004 requires a runtime selection layer (`PUP_RUNTIME=python|elixir|auto`); only binary `is_pup_ex()` detection exists. No `auto-fallback` mode.
3. **Significant plugin parity gap** — 32 of 46 Python plugins in scope (70%) have no Elixir equivalent. Core plugins are ported; many secondary plugins are Python-only. This is a rollout risk and blocker for 100% Elixir-only cutover, but not a blocker for Phase H infra work.

**Secondary concerns (non-blocking but should be tracked):**
- 13 of 19 specialized Python agents lack Elixir equivalents (but the base_agent behaviour + core agents are ported; many are prompt-only variants)
- Browser automation tools (4,750 LoC) have no Elixir equivalent — declared DROP-V1 in THIN_SHELL_CONTRACT
- Elixir TUI has 3 screens vs Python's 17 screens — TUI was audited as opt-in, so CLI parity matters more
- No `--continue` session restore implementation (parsed but no-op)
- No `--bridge-mode` runtime effect (parsed, reserved, no spec)
- CronScheduler Ecto-sandbox contention (~15 workflow test failures in test env)
- 6 open Phase D follow-ups (test quality, type spec fixes)

**Verdict:** Phases A–G are complete against their scoped roadmap/ADR exit criteria (not absolute full Python surface parity). Phase H needs new infrastructure (feature flags, runtime selector) before any gradual rollout can begin. Plugin parity is a rollout risk and a blocker for 100% Elixir-only cutover, but not a blocker for Phase H infra work itself — the bridge allows _some_ callback/custom-command/help functionality to be reached from Elixir, but does not provide full lifecycle/state/hook parity for arbitrary Python plugins.

---

## Parity Matrix

### Phase B: LLM Client — ✅ COMPLETE

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| Provider registry (ModelFactory) | `model_factory.py` (1,004 LoC) | `ModelFactory.ProviderRegistry` (Agent-backed) | ✅ Full |
| Streaming HTTP client | `httpx` + SSE | `HttpClient.Streaming` (Finch) | ✅ Full |
| OpenAI provider | `reopenable_async_client.py` | `LLM.Providers.OpenAI` | ✅ Full |
| Anthropic provider | `reopenable_async_client.py` | `LLM.Providers.Anthropic` | ✅ Full |
| Azure provider | via OpenAI | `LLM.Providers.Azure` | ✅ Full |
| Google provider | — | `LLM.Providers.Google` | ✅ Full |
| Groq provider | — | `LLM.Providers.Groq` | ✅ Full |
| Together provider | — | `LLM.Providers.Together` | ✅ Full |
| Tool-call dispatch | `base_agent.py` | `Agent.Loop` + `LLMAdapter` | ✅ Full |
| Model registry / packs | `model_registry.py` | `ModelRegistry` + `ModelPacks` | ✅ Full |
| Model availability / circuit breaker | `model_availability.py` | `ModelAvailability` | ✅ Full |
| Round-robin rotation | `round_robin_model.py` | `RoundRobinModel` | ✅ Full |
| Token estimation | `token_counting.py` | `Tokens.Estimator` | ✅ Full |
| Token ledger | `token_ledger.py` | `TokenLedger` | ✅ Full |
| Models.dev parser | `models_dev_parser.py` | `ModelsDevParser.Registry` | ✅ Full |
| Model pinning | `agent_model_pinning.py` | `AgentModelPinning` | ✅ Full |

### Phase C: Base Agent / Session — ✅ COMPLETE

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| Base agent behaviour | `base_agent.py` (3,152 LoC) | `Agent.Behaviour` + concerns | ✅ Full |
| Prompt mixin | `agent_prompt_mixin.py` | `Agent.PromptMixin` | ✅ Full |
| Event/subagent stream | `event_stream_handler.py` | `Agent.EventStreamHandler` + `SubagentStreamHandler` | ✅ Full |
| Agent manager | `agent_manager.py` (37.6K) | `Tools.AgentManager` (GenServer) | ✅ Full |
| Agent state | `agent_state.py` | `Agent.State` (RuntimeState) | ✅ Full |
| Agent behaviour callbacks | — | `Agent.Behaviour` callbacks | ✅ Full |
| CodePuppyAgent e2e | `agent_code_puppy.py` | `Agents.CodePuppy` | ✅ Full |
| Agent protocol | — | `Agent.Protocol` | ✅ Full |
| Budget enforcer | implicit | `Agent.BudgetEnforcer` | ✅ Full |
| Tool call tracker | — | `Agent.ToolCallTracker` | ✅ Full |
| Turn management | — | `Agent.Turn` | ✅ Full |
| Usage limits | — | `Agent.UsageLimits` | ✅ Full |
| Compaction | `compaction/` | `Compaction` + `ShadowMode` | ✅ Full |

### Phase D: Session + State — ✅ COMPLETE

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| Session storage | `session_storage.py` (34K) | `SessionStorage` (ETS + PubSub + File) | ✅ Full |
| Config system | `config/` (2,900 LoC) | `Config` (18.7K) + isolation | ✅ Full |
| Dual-home isolation | ADR-003 | `Config.Isolation` + `Paths` | ✅ Full |
| Runtime state | `runtime_state.py` | `RuntimeState` (GenServer) | ✅ Full |
| Persistence | `persistence.py` | `Persistence` (13.6K) | ✅ Full |
| Workflow state | `workflow_state.py` | `Workflow` + `WorkflowState` | ✅ Full |
| Staged changes | `staged_changes.py` | `StagedChanges` (16K) | ✅ Full |
| State migration tool | `plugins/state_migration/` | `SessionStorage.Migrator` | ✅ Full |
| Autosave tracker | — | `AutosaveTracker` | ✅ Full |
| Terminal recovery | — | `TerminalRecovery` | ✅ Full |

**Open follow-ups (non-blocking):**
- `save_session_async/3` Store-routing test mislabeled
- `load_session_full/2` type/spec atom-vs-string key mismatch
- Store operation error returns could crash on persistence errors
- CronScheduler Ecto-sandbox contention (pool_size: 1)

### Phase E: Tools — ✅ COMPLETE (scoped); ❌ PARTIAL (browser tools DROP-V1)

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| File operations | `file_operations.py` | `CpFileOps` + `FileOps` | ✅ Full |
| Command runner + PTY | `command_runner.py` (65K) | `CommandRunner` + executor/PTY | ✅ Full |
| File modifications | `file_modifications.py` | `FileModifications` (create/delete/replace/edit) | ✅ Full |
| Agent tools / invocation | `agent_tools.py` | `AgentInvocation` + `AgentCatalogue` | ✅ Full |
| Skills | `skills_tools.py` | `Skills` | ✅ Full |
| Universal constructor | `universal_constructor.py` | `UniversalConstructor` + registry | ✅ Full |
| Ask user question | `ask_user_question/` | `CpAskUserQuestion` | ✅ Full |
| Permission callbacks | `permission_decision.py` + plugins | `Callbacks.FilePermission` + `Security` | ✅ Full |
| Staged changes tools | — | `StagedChanges.Tools` | ✅ Full |
| Scheduler tools | `scheduler_tools.py` | `SchedulerTools` | ✅ Full |
| Subagent context | `subagent_context.py` | `SubagentContext` | ✅ Full |
| Process runner | `process_runner_protocol.py` | `ProcessRunner` | ✅ Full |
| **Browser tools** | `browser/` (4,750 LoC) | — | ❌ **Not ported** (DROP-V1 per THIN_SHELL_CONTRACT — accepted deferral) |

### Phase F: Plugins — ✅ SCOPED COMPLETE (core infra), ⚠️ PARTIAL (long tail — 14/46 ported)

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| Plugin loader | `plugins/__init__.py` | `Plugins.Loader` (ADR-006) | ✅ Full |
| Hook engine | `hook_engine/` (8 files) | `HookEngine` (7 files) | ✅ Full |
| Callback registry | `callbacks.py` (42K) | `Callbacks` + `Hooks` + `Registry` | ✅ Full |
| Plugin behaviour | — | `PluginBehaviour` | ✅ Full |
| Plugin .exs support | — | `Loader` discovers `.ex` + `.exs` | ✅ Full |
| Pack parallelism | `pack_parallelism/` | `PackParallelism` (GenServer) | ✅ Full |
| OAuth plugins | `chatgpt_oauth/` + `claude_code_oauth/` | `ChatgptOauth` + `ClaudeCodeOauth` | ✅ Full |

**Plugin Parity Inventory — Methodology & Counts**

Methodology:
- Enumerated all directories under `code_puppy/plugins/` (48 total)
- Excluded `elixir_bridge` (1): Python-side infrastructure, not a portable plugin
- Excluded `state_migration` (1): ported to core as `SessionStorage.Migrator`, not as a plugin
- Effective Python plugin count for parity: **46**
- Checked for Elixir equivalents under `elixir/code_puppy_control/lib/code_puppy_control/plugins/` (29 .ex files across 14 plugin directories + 2 infrastructure modules: `loader`, `plugin_behaviour`)
- A plugin is "ported" if it has a corresponding Elixir module or directory implementing equivalent functionality

| Category | Count | Percentage |
|----------|-------|------------|
| Total Python plugin dirs | 48 | — |
| Excluded (infrastructure) | 1 (`elixir_bridge`) | — |
| Excluded (ported to core) | 1 (`state_migration` → `SessionStorage.Migrator`) | — |
| Effective parity scope | **46** | — |
| Ported as Elixir plugin | **14** | 30% (14/46) |
| Not ported | **32** | 70% (32/46) |

**Ported (14/46):**
agent_memory, agent_trace, chatgpt_oauth, claude_code_oauth, cost_estimator, error_classifier, fast_puppy, file_mentions, git_auto_commit, loop_detection, motd, pack_parallelism, scheduler, turbo_executor

**Not ported (32/46):**
agent_shortcuts, agent_skills, auto_test_control, claude_code_hooks, clean_command, code_explorer, code_skeleton, completion_notifier, customizable_commands, dual_home, error_logger, example_custom_command, file_permission_handler, frontend_emitter, hook_creator, hook_manager, ollama_setup, pop_command, proactive_guidance, prompt_store, remember_last_agent, render_check, repo_compass, session_logger, shell_safety, supervisor_review, synthetic_status, theme_switcher, tool_allowlist, tracing_langfuse, tracing_langsmith, ttsr, universal_constructor

> **Assessment:** Most unported plugins are secondary/convenience plugins. The bridge allows _some_ callback/custom-command/help functionality to be reached from Elixir, but does not provide full lifecycle/state/hook parity for arbitrary Python plugins. Plugin parity is a **rollout risk** and a **blocker for 100% Elixir-only cutover** — unless accepted as DROP/DEFER/BRIDGE — but is **not a blocker for Phase H infra work** (feature flags, runtime selector, gradual rollout controller). The critical-path plugins (callbacks, hook engine, loader, OAuth, pack parallelism) are all ported.

### Phase G: CLI + UI — ✅ SCOPED COMPLETE; ⚠️ PARTIAL (TUI, slash-command/MCP surface)

| Capability | Python | Elixir | Parity |
|------------|--------|--------|--------|
| Interactive loop / REPL | `interactive_loop.py` (28K) | `REPL.Loop` + `Dispatch` + `History` | ✅ Full |
| Slash commands | `command_line/` (58 files, 17K LoC) | `CLI.SlashCommands` (16 built-ins + dispatcher) | ⚠️ Scoped complete — core commands ported; plugin-bridged commands reachable via bridge, not natively |
| MCP CLI | `command_line/mcp/` (23 files) | `CLI.SlashCommands.Commands.MCP` + `MCPLifecycle` | ⚠️ Scoped complete — lifecycle management ported; edge-case MCP tool surfaces may differ |
| TUI | `tui/` (Textual) | `TUI` (Owl — ADR-007) | ⚠️ Partial/accepted deferral — 3 screens vs Python's 17; TUI audited as opt-in (see docs/TUI_CLI_AUDIT.md); CLI parity matters more |
| CLI parser | `cli_runner.py` | `CLI.Parser` | ✅ Full |
| Completion | `prompt_toolkit_completion.py` | `REPL.Completion` | ✅ Full |
| GAC (Git Auto Commit CLI) | — | `Mix.Tasks.Gac` | ✅ Full |
| Burrito releases | — | `burrito_steps/` + release config | ✅ Full |

**Open follow-ups (non-blocking):**
- O(n²) `++` in Renderer.Buffer
- Replace `Task.shutdown(:brutal_kill)` with graceful shutdown
- `--continue` session restore (parsed, no-op)
- `--bridge-mode` runtime effect (parsed, no spec)
- TUI coverage gaps (ModelSelector 7%, SessionBrowser 18%)
- 6 renderer/test quality items

### Phase H: Cutover — ❌ NOT STARTED

> **Blocker categories:**
> - **Before any gradual rollout can begin:** Feature flags, runtime selector
> - **Before 100% Elixir default:** Gradual rollout controller, rollout-specific observability
> - **Before Python tree deletion:** 100% sustained Elixir operation, plugin parity resolution (DROP/DEFER/BRIDGE each unported plugin)

| Capability | Spec (ADR-004) | Current State | Gap | Blocks |
|------------|----------------|---------------|-----|--------|
| Feature flags (`flags.json`) | Per-capability toggles in `~/.code_puppy_ex/flags.json` | **Does not exist** — no `FeatureFlag` module, no `flags.json` | ❌ **BLOCKER** | Gradual rollout |
| Runtime selector | `PUP_RUNTIME=python\|elixir\|auto` with fallback | Only `is_pup_ex()` binary detection + `PUP_RUNTIME=elixir` | ❌ **BLOCKER** | Gradual rollout |
| Gradual rollout | Canary → 100% per capability | No rollout infrastructure | ❌ **BLOCKER** | 100% Elixir default |
| Rollout-specific observability | Metrics on which runtime handled each request | No rollout-specific observability (general telemetry exists) | ⚠️ **GAP** | 100% Elixir default |
| Python tree deletion | When Elixir at parity | Deferred — 32 unported plugins | ⚠️ Deferrable | Python deletion |
| Plugin parity resolution | Each unported plugin: DROP/DEFER/BRIDGE | No per-plugin decisions made | ⚠️ Deferrable | Python deletion |
| `--continue` session restore | Roadmap item | Parsed but no-op | ⚠️ Low priority | — |
| `--bridge-mode` effect | Roadmap item | Parsed, reserved, no spec | ⚠️ Low priority | — |
| CONTRIBUTING.md update | code_puppy-djs.7 | Not started | ⚠️ Trivial | — |

---

## Blocking Gaps — Detailed

### BLOCKER 1: Feature-Flag System

**What ADR-004 requires:**
```json
{
  "elixir.llm_client": false,
  "elixir.base_agent": false,
  "elixir.tools": false,
  "elixir.plugins": false,
  "elixir.cli": false
}
```
Each flag enables a phase's capabilities. Flags are independent; partial enablement for canary.

**What exists:**
- `PUP_RUNTIME=elixir` env var — binary on/off only
- `enable_elixir_message_shadow_mode` config toggle — shadow mode for message ops only
- `Config.Debug` module — many feature toggles, but none for Elixir/Python runtime routing
- No `flags.json` file, no `FeatureFlag` module, no per-capability toggle system

**Evidence:** `grep -r 'FeatureFlag\|feature_flag' elixir/` returns 0 results. `grep -r 'flags.json' elixir/` returns 0 results.

**What needs to be built:**
1. Elixir: `CodePuppyControl.FeatureFlags` GenServer — reads `flags.json`, exposes `enabled?(capability)` API
2. Python: `FeatureFlagClient` — reads same `flags.json` (or mirrors via bridge)
3. CLI: `/flags` slash command exists (`CLI.SlashCommands.Commands.Flags` — see `elixir/code_puppy_control/lib/code_puppy_control/cli/slash_commands/commands/flags.ex`) but is wired to `WorkflowState` flags only, not to the ADR-004 feature-flag system. Needs extension or a separate `/feature-flags` command.
4. Startup: Both runtimes check flags at boot to determine routing

**Recommended issue:** `code_puppy-djs.4` (Feature-flag Elixir code paths) — currently open, needs scope expansion

### BLOCKER 2: Runtime Selector / Dual-Run Router

**What ADR-004 requires:**

| Mode | Selection Logic |
|------|----------------|
| Python-only | `PUP_RUNTIME=python` or no Elixir backend |
| Elixir-only | `PUP_RUNTIME=elixir` and Elixir backend available |
| Dual-run with routing | Feature flag maps request types to runtime |
| Auto-fallback | If selected runtime fails, fallback to other if available |

**What exists:**
- `config_paths.is_pup_ex()` — returns True/False based on `PUP_EX_HOME` or `PUP_RUNTIME=elixir`
- `elixir_bridge/__init__.py` — `is_connected()`, `call_method()` for Python→Elixir calls
- `bridge_controller.py` — 48 JSON-RPC handlers for Elixir→Python calls
- No `auto` mode, no fallback, no request-type routing

**Evidence:** `grep -r 'PUP_RUNTIME\|is_pup_ex\|auto.*fallback' code_puppy/config_paths.py` shows only binary detection. `grep -r 'auto_fallback\|request.*routing' elixir/` returns 0 results.

**What needs to be built:**
1. Runtime selector module (both Python + Elixir) — tri-state: python / elixir / auto
2. Request router — maps request types (llm_client, tools, plugins, cli) to runtime based on feature flags
3. Auto-fallback — if primary runtime fails, try secondary
4. Doctor integration — `pup doctor` reports active runtime

**Recommended issue:** `code_puppy-bwt` — Runtime selector + dual-run router (child of `code_puppy-djs`)

### BLOCKER 3: Gradual Rollout Infrastructure

**What ADR-004 requires:** Canary → 100% per capability, not all-at-once.

**What exists:** Nothing. No rollout controller, no percentage-based enablement, no rollout-specific observability (general Elixir telemetry exists — `:telemetry.attach/3` calls in supervision tree — but no metrics on which runtime handled a given request).

**What needs to be built:**
1. Rollout controller — per-capability percentage (0% → 5% → 25% → 50% → 100%)
2. Observability — rollout-specific metrics: which runtime handled each request type, per-capability success/error rates, fallback counts. Evidence: `grep -r 'telemetry' elixir/code_puppy_control/lib/` shows existing telemetry attachments in application.ex and config modules; these need extension for runtime-routing metrics.
3. Rollback trigger — automatic revert if error rate exceeds threshold

**Recommended issue:** `code_puppy-djs.6` (Gradual rollout per capability) — currently open, needs spec

---

## Non-Blocking Concerns

| Concern | Severity | Notes |
|---------|----------|-------|
| 32 unported Python plugins (70%) | Medium | Bridge allows some callback/custom-command/help to be reached; not a blocker for Phase H infra work, but a rollout risk and blocker for 100% Elixir-only cutover unless accepted as DROP/DEFER/BRIDGE |
| Browser tools (4,750 LoC) | Low | Declared DROP-V1 (accepted deferral); no Elixir browser automation ecosystem |
| 13 unported specialized agents | Low | Most are prompt-only variants; base behaviour is ported |
| TUI screen parity (3 vs 17) | Low | TUI is opt-in/accepted deferral (see docs/TUI_CLI_AUDIT.md); CLI parity is scoped complete |
| `--continue` session restore | Low | Parsed but no-op; not rollout-blocking |
| `--bridge-mode` effect | Low | No spec; deferred |
| CronScheduler test contention | Low | Pre-existing, not a regression |
| Phase D follow-ups (6 items) | Low | Test quality, type specs; not runtime-blocking |

---

## Recommended Next Steps

### Immediate (before rollout can begin)

1. **Scope `code_puppy-djs.4`** — Feature-flag system implementation
   - Add `FeatureFlags` GenServer in Elixir
   - Add `flags.json` read/write + CLI `/flags` wiring
   - Define capability enum: `llm_client, base_agent, tools, plugins, cli`

2. **Scope `code_puppy-bwt`** — Runtime selector + dual-run router (already filed, child of `code_puppy-djs`)
   - Tri-state: `python | elixir | auto`
   - Request-type routing based on feature flags
   - Auto-fallback with error reporting
   - Doctor integration

3. **Scope `code_puppy-djs.6`** — Gradual rollout controller
   - Per-capability percentage enablement
   - Observability / metrics
   - Automatic rollback trigger

### After rollout infrastructure is ready

4. **Run shadow-mode validation** — Enable `enable_elixir_message_shadow_mode` for all message ops, collect divergence reports
5. **Canary test** — Route 5% of `llm_client` requests to Elixir, monitor
6. **Expand canary** — `tools` → `plugins` → `cli` one at a time
7. **100% Elixir** — All capabilities routed to Elixir; Python in fallback-only mode
8. **Python tree deletion** — `code_puppy-djs.2` (only after sustained 100% Elixir operation)

### Parallel / non-blocking

9. Port high-value unported plugins (shell_safety, file_permission_handler, repo_compass)
10. Implement `--continue` session restore
11. Resolve Phase D follow-ups
12. Improve TUI widget test coverage

---

## Codebase Metrics

> **Methodology:** Python counts via `find code_puppy/ -name '*.py' | wc -l` and `find code_puppy/ -name '*.py' -exec cat {} + | wc -l`. Elixir counts via `find elixir/code_puppy_control/lib/ -name '*.ex' | wc -l` and `find elixir/code_puppy_control/lib/ -name '*.ex' -exec cat {} + | wc -l`. Plugin counts: `ls -d code_puppy/plugins/*/ | wc -l` (48 dirs) and `find elixir/code_puppy_control/lib/code_puppy_control/plugins -name '*.ex' | wc -l` (29 .ex files in 14 plugin dirs + 2 infra modules). Test counts: `find elixir/code_puppy_control/test/ -name '*_test.exs' | wc -l`.

| Metric | Python | Elixir |
|--------|--------|--------|
| Source files (lib/) | ~554 | ~868 |
| Source LoC | ~85,613 | ~79,031 |
| Test files | ~8 (top-level) | ~362 |
| Test functions (est.) | ~136 | ~5,500+ |
| Plugin dirs | 48 | 14 (plugin) + 2 (infra: loader, behaviour) |
| Plugin .ex files | — | 29 |
| Ported plugins (of 46 in scope) | — | 14 (30%) |
| Agents (core) | 8 | 8 |
| Agents (specialized) | 13 | 0 |
| CLI command files | 58 | 10 + 16 slash commands |
| TUI screens | 17 | 3 |
| TUI widgets | 4 | 3 |

---

## Files Inspected

- `ROADMAP.md` — Phase tracker, all Phases A–G marked complete
- `docs/adr/ADR-004-python-to-elixir-migration-strategy.md` — Migration phases, feature flags spec
- `docs/adr/ADR-006-elixir-plugin-loader.md` — Plugin loader design
- `docs/THIN_SHELL_CONTRACT.md` — What stays in Python after cutover
- `docs/acceleration.md` — NativeBackend routing, Elixir-first profile
- `docs/MIGRATION.md` — State migration tool (Python → Elixir home)
- `docs/TUI_CLI_AUDIT.md` — TUI/CLI parity precedent audit
- `code_puppy/config_paths.py` — `is_pup_ex()`, runtime detection
- `code_puppy/plugins/elixir_bridge/` — Bridge controller (48 JSON-RPC handlers)
- `code_puppy/config/debug.py` — Feature toggles (no Elixir routing flags)
- `elixir/code_puppy_control/lib/code_puppy_control/config/debug.ex` — Elixir feature toggles
- `elixir/code_puppy_control/lib/code_puppy_control/application.ex` — Full supervision tree
- `elixir/code_puppy_control/lib/code_puppy_control/compaction/shadow_mode.ex` — Shadow mode (closest to feature-flag pattern)

---

## Conclusion

Phases A–G are **complete against their scoped roadmap/ADR exit criteria** — not against absolute full Python surface parity. The Elixir codebase is mature (79K LoC, 362 test files, comprehensive supervision tree). Phase H's three blockers are all **new infrastructure** that must be built before any gradual rollout:

1. Feature-flag system (spec in ADR-004, no implementation) — **blocks gradual rollout**
2. Runtime selector with dual-run routing (spec in ADR-004, no implementation, issue `code_puppy-bwt`) — **blocks gradual rollout**
3. Gradual rollout controller (spec in ADR-004, no implementation) — **blocks 100% Elixir default**

Additionally:
- Rollout-specific observability — **needed before 100% Elixir default**
- Plugin parity resolution (DROP/DEFER/BRIDGE per plugin) — **needed before Python tree deletion**
- 32 unported Python plugins — **rollout risk and blocker for 100% Elixir-only cutover** unless accepted as DROP/DEFER/BRIDGE

The good news: the Phase H blockers are self-contained, buildable features, not deep architectural gaps. The bridge already provides bidirectional Python↔Elixir communication. The bad news: until the infra blockers are resolved, Phase H is blocked on infrastructure, not parity.

**Issue code_puppy-djs.1 should be closed after Shepherd/Watchdog review of this audit.**
