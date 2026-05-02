# ADR-004: Python-to-Elixir Migration Strategy

## Status

**ACCEPTED** (2026-04-25)

## Context

Code Puppy is migrating its runtime from Python to Elixir in phases. This is not a "big bang" rewrite but a gradual, reversible transition where both runtimes coexist during the migration period. The migration touches every layer of the system: agent execution, tool dispatch, session management, config handling, and the plugin ecosystem.

Key decisions already resolved:

- **Elixir app naming**: Decided to keep `code_puppy_control` as the internal OTP app name; user-facing name is `pup-ex` ([ELIXIR-APP-NAMING.md](ELIXIR-APP-NAMING.md))
- **Dual-home config isolation**: Elixir pup-ex uses `~/.code_puppy_ex/`; never writes to `~/.code_puppy/` ([ADR-003](ADR-003-dual-home-config-isolation.md))
- **Elixir-Python worker protocol**: JSON-RPC 2.0 over stdio with Content-Length framing ([ADR-001](ADR-001-elixir-python-worker-protocol.md))
- **Python-to-Elixir event protocol**: Generic `event` method with `event_type` discrimination ([ADR-002](ADR-002-python-elixir-event-protocol.md))
- **Test baseline**: 5184 Elixir tests pass with 0 failures (triage completed)

Previously open items (resolved during Phase A):

- **Baseline performance benchmarks**: ✅ Established — offline filesystem primitives + credential-gated LLM latency probes; no live baseline numbers committed
- **Python dependency graph**: ✅ Mapped — see `docs/python_dependency_graph.md`; SCC-based topological ordering, reproducible

## Decision

**Adopt a phased, capability-by-capability migration with dual-run capability and rollback safety.**

The migration proceeds in 8 phases (0 → H), with Python remaining functional throughout. Cutover is reversible until Phase H. Each phase has defined entry/exit criteria and rollback procedures.

### Migration Principles

| Principle | Description |
|-----------|-------------|
| **Dual-run by default** | Both Python and Elixir runtimes are operational during migration; no "maintenance mode" outages |
| **Rollback at any checkpoint** | Each phase can be reverted without data loss; rollback is a first-class operation |
| **Truthful status** | ADR does not claim work is done before it is; resolved items are updated in-place as phases complete |
| **Feature-flag driven** | New Elixir capabilities are guarded by runtime flags; gradual rollout per environment |
| **No user disruption** | Users continue running `pup` without knowing which runtime executes their request |

## Scope

### In Scope

- Porting agent execution engine from Python to Elixir
- Porting tool layer (file ops, command runner, grep) to Elixir-native
- Porting session storage and runtime state management
- Porting config system with dual-home isolation
- Porting plugin callback system
- Establishing reversible cutover mechanism

### Explicit Non-Goals

- **Performance parity as a blocker**: Baseline benchmarks are established (harness + offline primitives); however, migration proceeds on feature completeness, not speed parity — live credentialed LLM latency is operator-local and not committed
- **Plugin API stability**: Plugin authors may need to adapt during migration; no frozen API guarantee until Phase G
- **Remote/distributed workers**: Out of scope; migration assumes local subprocess architecture
- **Python runtime improvements**: Python code is frozen; no new features or refactors during migration
- **Third-party MCP server migration**: Existing MCP integrations stay as-is; new MCP support is deferred

## Phased Migration Approach

### Phase 0: Pre-Port Hygiene (COMPLETE)

| Item | Status |
|------|--------|
| Remove bd tracker (HISTORICAL: removed in `b94b6222`; restored in `147cfa2b`) | ✅ Done (post-dated by restoration) |
| Add local test gates to git hooks | ✅ Done (lefthook → native git hooks) |
| Create ROADMAP.md | ✅ Done |
| Triage 121 pre-existing Elixir test failures | ✅ Done (5184 tests pass) |
| Triage pre-existing ruff errors | ✅ Done |
| Choose Elixir umbrella app naming | ✅ Done ([ELIXIR-APP-NAMING.md](ELIXIR-APP-NAMING.md)) |

**Exit criteria**: All gates pass; Elixir test suite is green.

### Phase A: Port Planning Formalization (COMPLETE)

| Item | Status |
|------|--------|
| Write ADR-004 (this document) | ✅ Accepted |
| Baseline performance benchmarks | ✅ Done — offline filesystem primitives + credential-gated LLM latency probes; no live baseline numbers committed |
| Python dependency graph for porting priority | ✅ Done — see `docs/python_dependency_graph.md`; SCC-based topological ordering, reproducible |

**Exit criteria**: Met — ADR-004 accepted; benchmarks and dependency graph complete.

### Phase B: Elixir LLM Client (COMPLETE)

Port the model layer to Elixir-native implementation.

- ✅ Port `code_puppy/model_factory.py` — provider registry (e0a481dc ProviderRegistry core merge + c2a5738f ModelFactory integration merge)
  - `CodePuppyControl.ModelFactory.ProviderRegistry` — Agent-backed concurrency-safe `%{type => module}` registry
  - `ModelFactory.provider_module_for_type/1` now delegates to `ProviderRegistry.lookup/1`
  - `lookup_provider/1` preserves `:error` fallback for non-binary types
  - Tests cover: runtime register/override, `reset_for_test/0`, `list_available/0`, `resolve/1`, malformed non-binary type rejection, provider-map parity (110 model_factory tests + 29 LLM/parity tests pass)
- ✅ Port `code_puppy/messaging/*` — message types and serialization
  - `073335a1` — structured message schema foundation
  - `366101ca` — UI command schema serialization
  - `45cbe34e` — Agent UI message families
  - `3e67001e` — EventBus wire events
  - Post-merge smoke: 521 tests / 0 failures (EventBus structured, EventsChannel, messaging, message_core, serializer)
  - Completed modules: `CodePuppyControl.Messaging.Types`, `Messaging.Messages` facade + split families, `Messaging.WireEvent`, `Messaging.Commands`, EventBus wire-envelope helpers, EventStore legacy `type` + structured `event_type` filtering
- ✅ Elixir-native streaming HTTP client (code_puppy-9l1)
  - `CodePuppyControl.HttpClient.Streaming` submodule
  - Hardened `HttpClient.stream/3` contract: 2xx → `{:data,…}/{:done,…}`; non-2xx/transport → `{:error,…}`
  - OpenAI + Anthropic provider streaming error tests
  - Full post-merge suite: 5688 tests, 0 failures, 107 excluded; 89 properties; 9 doctests
- ✅ Tool-call dispatch plumbing (code_puppy-j05)
  - `Agent.Loop` appends `assistant(tool_calls)` before tool-result messages
  - `LLMAdapter` preserves/converts assistant tool_calls to provider shape safely
  - Anthropic nil-content replay emits `tool_use`/`tool_result` blocks
  - Malformed tool calls and atom safety tested

**Exit criteria**: Met — Elixir can make LLM requests without Python proxy; all unit tests pass. All four Phase B sub-items (provider registry, messaging, streaming HTTP client, tool-call dispatch) are merged and tested. No live credentialed LLM baseline numbers were committed as part of this work.

### Phase C: Base Agent Port

Port core agent runtime to Elixir.

- Port `code_puppy/agents/base_agent.py`
- Port `code_puppy/agents/agent_manager.py`
- Agent registry in Elixir
- Behaviour/protocol definitions

**Exit criteria**: Single agent type (e.g., `CodePuppyAgent`) runs end-to-end in Elixir.

### Phase D: Session + State

Port persistence and state management.

- Port session storage (Phoenix PubSub + ETS + disk)
- Port config system (dual-home isolation, see ADR-003)
- Port runtime state

**Exit criteria**: Sessions survive Elixir restarts; config is isolated; state is inspectable.

### Phase E: Tools

Port the tool layer.

- Port `code_puppy/tools/*` (file ops, command runner, grep)
- Port tool permission callbacks

**Exit criteria**: All tools have Elixir implementations; permission callbacks fire correctly.

### Phase F: Plugins

Port the plugin ecosystem.

- [x] Design Elixir plugin loader equivalent → ADR-006 accepted
- [x] Port callback system (`code_puppy/callbacks.py`) → `CodePuppyControl.Callbacks` + `Hooks`
- [ ] Port pack-parallelism plugin

**Exit criteria**: Core plugins load in Elixir; callback hooks fire in order.

### Phase G: CLI + UI

Port the user interface layer.

- Port interactive loop
- Port command line / slash commands
- TUI in Elixir (Owl or Ratatouille)

**Exit criteria**: Users can run full sessions via Elixir-only; Python is optional.

### Phase H: Cutover

Final transition and Python deprecation.

- Feature-flag Elixir code paths (gradual rollout)
- Gradual rollout per capability (canary → 100%)
- Delete Python tree when Elixir is at parity

**Exit criteria**: Python code removed; Elixir is sole runtime.

## Dual-Run / Rollback Strategy

### Runtime Selection (Required Implementation)

The `pup` binary must implement runtime selection based on feature flags and environment:

| Mode | Required Selection Logic |
|------|--------------------------|
| **Python-only** (default until Phase G) | `PUP_RUNTIME=python` or no Elixir backend |
| **Elixir-only** | `PUP_RUNTIME=elixir` and Elixir backend available |
| **Dual-run with routing** | Feature flag maps request types to runtime |
| **Auto-fallback** | If selected runtime fails, fallback to other if available |

### Rollback Procedures

| Phase | Rollback Action | Data Impact |
|-------|-----------------|-------------|
| Phase B-D | Set `PUP_RUNTIME=python` | None; Elixir state is disposable |
| Phase E-F | Set `PUP_RUNTIME=python`; Elixir plugins unload | Plugin state in Elixir lost; Python plugins reload |
| Phase G | Set `PUP_RUNTIME=python` | Sessions remain in Elixir home; user must re-import if switching back (no automatic sync) |
| Phase H | Git revert to pre-deletion commit | Full restoration possible |

### Feature Flag System (Required Implementation)

The feature flag system must store flags in `~/.code_puppy_ex/flags.json` (Elixir) and check them at runtime startup:

```json
{
  "elixir.llm_client": false,
  "elixir.base_agent": false,
  "elixir.tools": false,
  "elixir.plugins": false,
  "elixir.cli": false
}
```

Each flag will enable a phase's capabilities. Flags are independent; partial enablement will be supported for canary testing.

## Decision Drivers

| Driver | Rationale |
|--------|-----------|
| **Risk reduction** | Big-bang migrations fail; phased approach contains blast radius |
| **Reversibility** | Each phase must be undoable without user-visible data loss |
| **User continuity** | Users should not notice runtime switches; `pup` just works |
| **Contributor safety** | Clear boundaries let teams work in parallel without collision |
| **Observability** | Feature flags provide telemetry on Elixir stability |

## Consequences

### Positive

- **Incremental delivery**: Value is delivered phase-by-phase, not at the end
- **Rollback safety**: No phase is a point of no return until Phase H
- **Parallel development**: Python and Elixir teams can work simultaneously
- **Production validation**: Feature flags enable real-world testing before cutover

### Negative

- **Dual maintenance**: Some code exists in both Python and Elixir during migration
- **Complexity overhead**: Feature flag system adds branching logic
- **State isolation overhead**: Dual-home isolation (per ADR-003) requires explicit user action to migrate state between runtimes; no automatic synchronization
- **Longer timeline**: Phased approach takes more wall-clock time than rewrite

### Neutral

- **Benchmarks established, not comprehensive**: Offline harness and dependency graph are in place (Phase A); live credentialed LLM latency remains operator-local and is not committed to the repo
- **Porting order is data-informed**: Dependency graph (SCC-based) guides priority; refinements may occur as new modules are ported

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Phase H is irreversible** | Low | High | Keep Python code in git history; feature flags allow gradual enablement before deletion |
| **State isolation risk** | Medium | Medium | Homes remain isolated; users must explicitly export/import when switching runtimes; document rollback data visibility limitations (no automatic sync)
| **Plugin compatibility gaps** | Medium | Medium | Core plugins ported first; community plugins get migration guide |
| **Elixir performance regression** | Low | High | Benchmarks established before Phase H; rollback if metrics fail |
| **User confusion on runtime** | Low | Low | `pup` abstracts runtime selection; document runtime selection behavior; add doctor checks for active runtime before Phase G (required implementation)

## CI Gates

These gates must pass before each phase advances:

| Phase | Gate | Test |
|-------|------|------|
| Phase B | LLM connectivity | Elixir makes successful OpenAI request |
| Phase C | Agent end-to-end | Single agent runs full task without Python |
| Phase D | Session persistence | Restart Elixir; session resumes |
| Phase E | Tool parity | All tools have Elixir implementations |
| Phase F | Plugin load | Core plugins load without errors |
| Phase G | UI parity | TUI passes visual regression tests |
| Phase H | No Python dependency | Python runtime not imported anywhere |

## References

- [ROADMAP.md](../../ROADMAP.md) — Phase tracker and task breakdown
- [ADR-001](ADR-001-elixir-python-worker-protocol.md) — Elixir ↔ Python worker protocol
- [ADR-002](ADR-002-python-elixir-event-protocol.md) — Python → Elixir event protocol
- [ADR-003](ADR-003-dual-home-config-isolation.md) — Dual-home config isolation
- [ADR-006](ADR-006-elixir-plugin-loader.md) — Elixir plugin loader design (Phase F.1)
- [ELIXIR-APP-NAMING.md](ELIXIR-APP-NAMING.md) — Elixir app naming decision
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — System architecture overview

## Open Items (Non-Blocking)

The following items are tracked but do not block migration progress:

- **Live credentialed LLM baseline numbers**: Operator-local only; not committed to repo; may inform Phase H go/no-go when shared
- **Elixir performance regression benchmarking**: Formal Phase H go/no-go gate depends on comparative numbers; deferred until feature parity is near
- **Community plugin migration guide**: Needed before Phase G; does not block current porting work

---

**Decision Date**: 2026-04-25
**Decision Maker**: Code Puppy Migration Team
**Status**: Accepted
