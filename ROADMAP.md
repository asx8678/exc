# Code Puppy Roadmap

> Historical/high-level phase summary. Active work is tracked in **bd** (beads) — see `bd ready` for available tasks.
>
> This file documents phase completion status and follow-ups. Do not add new active work items here;
> file them in bd instead. ROADMAP is not a replacement for bd — bd is the canonical tracker for in-progress work.

## Format

- `- [ ]` open
- `- [x]` done
- `- [~]` in progress (on a branch)
- `- [?]` blocked / needs decision

Update in the same commit that advances the work. Close an item only when merged to main.

---

## Active

### Phase 0: Pre-port hygiene

Prerequisites before launching the Python-to-Elixir port.

- [x] Remove bd tracker (HISTORICAL: done in commit `b94b6222`; bd was later restored as canonical tracker in `147cfa2b` — see `bd ready` for current workflow)
- [x] Add local test gates to lefthook (this commit)
- [x] Create ROADMAP.md (this commit)
- [x] Triage 121 pre-existing Elixir test failures (delete / fix / skip-with-reason) — baseline now passes: 5184 tests, 0 failures
- [x] Triage pre-existing ruff errors on Python side (code_puppy-230 — all 44 errors fixed)
- [x] Choose final naming for the Elixir umbrella app (currently `code_puppy_control`) — see [docs/adr/ELIXIR-APP-NAMING.md](docs/adr/ELIXIR-APP-NAMING.md)

### Phase A: Port planning formalization

- [x] Write ADR-004: Python-to-Elixir migration strategy (scope, phases, rollback) — see [docs/adr/ADR-004-python-to-elixir-migration-strategy.md](docs/adr/ADR-004-python-to-elixir-migration-strategy.md)
- [x] Baseline performance harness (tools) — see [docs/benchmarks/README.md](docs/benchmarks/README.md); offline filesystem primitives measured
- [x] Baseline performance harness (LLM latency probe) — credential-gated TTFB probe implemented; requires PUP_ANTHROPIC_API_KEY or PUP_OPENAI_API_KEY; no live baseline numbers committed
- [x] Baseline performance (LLM latency — streaming TTFT/TBT) — streaming probes implemented (credential-gated); live numbers remain operator-local and are not committed; see [docs/benchmarks/llm_latency.md](docs/benchmarks/llm_latency.md)
- [x] Dependency graph of Python modules — see [docs/python_dependency_graph.md](docs/python_dependency_graph.md) — complete: SCC-based topological ordering (dependency-before-importer guaranteed for acyclic edges), relative import semantics fixed, symbol-level deps excluded, self-tests 14/14, reproducible artifacts, semantic sanity verified

### Phase B: Elixir LLM client

- [x] Port `code_puppy/model_factory.py` — provider registry (e0a481dc ProviderRegistry core merge + c2a5738f ModelFactory integration merge; `CodePuppyControl.ModelFactory.ProviderRegistry` backed by Agent; `ModelFactory.provider_module_for_type/1` delegates to `ProviderRegistry.lookup/1`; tests: runtime register/override, `reset_for_test/0`, `list_available/0`, `resolve/1`, malformed non-binary type rejection, provider-map parity — 110 model_factory tests + 29 LLM/parity tests pass)
- [x] Port `code_puppy/messaging/*` — message types and serialization (073335a1, 366101ca, 45cbe34e, 3e67001e; smoke 521/0 across EventBus structured, EventsChannel, messaging, message_core, serializer; Types + Messages facade + split families, WireEvent, Commands, EventBus wire-envelope helpers, EventStore legacy `type` + structured `event_type` filtering)
- [x] Elixir-native streaming HTTP client for OpenAI / Anthropic / local models (code_puppy-9l1 — `CodePuppyControl.HttpClient.Streaming`; hardened `HttpClient.stream/3`: 2xx → `{:data,…}/{:done,…}`, non-2xx/transport → `{:error,…}`; OpenAI + Anthropic provider streaming error tests; full post-merge suite: 5688 tests, 0 failures, 107 excluded; 89 properties; 9 doctests)
- [x] Tool-call dispatch plumbing (code_puppy-j05 — `Agent.Loop` appends `assistant(tool_calls)` before tool-result messages; `LLMAdapter` preserves/converts assistant tool_calls to provider shape safely; Anthropic nil-content replay emits `tool_use`/`tool_result` blocks; malformed tool calls and atom safety tested)

> **Phase B is now complete.** All four sub-items (provider registry, messaging, streaming HTTP client, tool-call dispatch) are merged and tested. No live credentialed LLM baseline numbers were committed as part of this work.

### Phase C: Base agent port

> Tracking: epic `code_puppy-4s8` (filed 2026-04-25), 7 child tasks: <C.1: `code_puppy-4s8.1`>, <C.2: `code_puppy-4s8.4`>, <C.3: `code_puppy-4s8.6`>, <C.4: `code_puppy-4s8.5`>, <C.5: `code_puppy-4s8.2`>, <C.6: `code_puppy-4s8.3`>, <C.7: `code_puppy-4s8.7`>


- [x] Port base_agent.py to Elixir behaviour + concern modules — code_puppy-4s8.1, merged e82cde9d
- [x] Port agent_prompt_mixin.py + resolve UNK3 (load_prompt scope) — code_puppy-4s8.2, merged 53f803d3
- [x] Port event/subagent stream handlers — code_puppy-4s8.3, merged d549ddf3
- [x] Port agent_manager.py to GenServer-backed registry — code_puppy-4s8.4, merged caa42809
- [x] Port agent_state.py to RuntimeState GenServer — code_puppy-4s8.5, merged 6cd78399
- [x] Define agent behaviour callbacks and runtime protocol — code_puppy-4s8.6, merged d83cccfe
- [x] Port CodePuppyAgent end-to-end as Phase C CI gate — code_puppy-4s8.7, merged e7f98f85

### Phase D: Session + state

> Tracking: epic `code_puppy-ctj` (filed 2026-04-25), 6 child tasks: <D.1: `code_puppy-ctj.1`>, <D.2: `code_puppy-ctj.2`>, <D.3: `code_puppy-ctj.4`>, <D.4: `code_puppy-ctj.3`>, <D.5: `code_puppy-ctj.5`>, <D.6: `code_puppy-ctj.6`>


- [x] Port session storage (Phoenix PubSub + ETS + disk) — code_puppy-ctj.1, merged 51a32908
- [x] Port config system (dual-home isolation, see ADR-003) — code_puppy-ctj.2, merged e0899a82
- [x] Port runtime state parity — code_puppy-ctj.4, merged 5c02374d
- [x] Port persistence + workflow_state — code_puppy-ctj.3, merged 63459657
- [x] Port staged changes system — code_puppy-ctj.5, merged bdfcbc1f
- [x] Add state migration tool — code_puppy-ctj.6, merged fb935a11

#### Phase D follow-ups (post-ctj.1)

- [x] Fix mislabeled `save_session_async/3` Store-routing test in `session_storage_async_test.exs:135-149` — fixed: Store-routing test at line 142-155 correctly tests without `base_dir:`
- [x] Add explicit Store-backed facade tests for `search_sessions/1` and `export_*` (call without `base_dir`, assert Store-backed behavior) — implemented in `session_storage_facade_test.exs`
- [x] Correct `load_session_full/2` type/spec — `@type session_data` uses atom keys but Store returns string-keyed maps (`session_storage.ex:54-62` vs `:149-163`) — typedoc clarified
- [x] Harden Store operation error returns — `Store.Operations.do_delete_session/1` and `do_recover_from_disk/0` pattern-match `:ok`/`{:ok, _}` and could crash on persistence errors — already hardened with try/rescue
- [x] Clarify `application.ex` supervision tree comment — currently says "Session storage ETS cache + PubSub" which echoes the removed dual-cache; reword to "SessionStorage.Store — ETS-backed session store + PubSub" — updated
- [x] Resolve CronScheduler Ecto-sandbox contention — `pool_size: 1` causes ~15 DB-dependent workflow test failures because CronScheduler holds the only connection. Either exclude scheduler in test env or raise pool_size. Pre-existing, not a regression. — resolved: CronScheduler excluded in test env via compile-time `@exclude_cron_scheduler` flag

### Phase E: Tools

> Tracking: epic `code_puppy-mmk` (filed 2026-04-25), 7 child tasks: <E.1: `code_puppy-mmk.1`>, <E.2: `code_puppy-mmk.5`>, <E.3: `code_puppy-mmk.6`>, <E.4: `code_puppy-mmk.4`>, <E.5: `code_puppy-mmk.3`>, <E.6: `code_puppy-mmk.7`>, <E.7: `code_puppy-mmk.2`>


- [x] Port file_operations.py to FileOps with permission gating — code_puppy-mmk.1, merged 878bc586
- [x] Port skills, scheduler, and universal constructor tools — code_puppy-mmk.2, merged e5195282
- [x] Port permission callback chain — code_puppy-mmk.3, merged 9fec97d1
- [x] Port agent_tools.py sub-agent invocation — code_puppy-mmk.4, merged 4d3d7339
- [x] Port FileModifications — code_puppy-mmk.5, merged 13d350ce
- [x] Port command_runner.py with PTY support — code_puppy-mmk.6, merged b88e0de6
- [x] Port cp_ask_user_question tool — code_puppy-mmk.7, merged 72dcf76e

### Phase F: Plugins

> Tracking: epic `code_puppy-154` (filed 2026-04-25), 6 child tasks: <F.1: `code_puppy-154.1`>, <F.2: `code_puppy-154.6`>, <F.3: `code_puppy-154.4`>, <F.4: `code_puppy-154.3`>, <F.5: `code_puppy-154.2`>, <F.6: `code_puppy-154.5`>


- [x] Plugin loader ADR + symlink escape fix + crash isolation — code_puppy-154.1, merged 5484f5a4
- [x] Port OAuth plugins to Elixir with builtin discovery — code_puppy-154.2, merged 05f29ef0
- [x] Elixir GenServer pack parallelism — code_puppy-154.3, merged c2524324
- [x] Port hook_engine to CodePuppyControl.HookEngine — code_puppy-154.4, merged 2cb01a92
- [x] Add PLUGIN_MIGRATION.md for community plugin authors — code_puppy-154.5, merged 61beaf72
- [x] Port callbacks.py to full hook surface — code_puppy-154.6, merged b097eb5b

### Phase G: CLI + UI

> Tracking: epic `code_puppy-prg` (filed 2026-04-25), 3 active tasks: <G.1: `code_puppy-prg.1`>, <G.2: `code_puppy-prg.2`>, <G.3: `code_puppy-prg.3`> (prg.4/5/6 unallocated — phantom bd IDs, no scope or commits)


- [x] Port interactive loop (REPL.Loop + Dispatch + History + Completion + Input + OneShot, 1681 LoC) — code_puppy-prg.1, landed via bd-160/bd-250/bd-252 (merge SHAs 3a131602, 1eced0ed, b47e54f6)
- [x] Port command line / slash commands (16 built-ins + Dispatcher + Registry + plugin bridge, 865 LoC) — code_puppy-prg.2, landed via bd-163/bd-259–bd-273 + plugin bridge (merged ca984ff5)
- [x] TUI in Elixir (Owl chosen — see ADR-007) — code_puppy-prg.3, merged 54e44fb6

> **Phase G is now complete.** All three sub-items (interactive loop, slash commands + plugin bridge, Elixir TUI) are merged. The only remaining phase is H (cutover). Tier 3 polish items moved to "Phase G follow-ups (post-prg.3)" below.


#### Phase G follow-ups (post-prg.3)

**Renderer / TUI robustness:**
- [x] Replace O(n²) `++` in `Renderer.Buffer` text accumulation with a reversed-list pattern (`[text | acc]` + reverse on flush) — `renderer/buffer.ex` — implemented: uses `[text | &1]` prepend + `Enum.reverse` on flush
- [x] Mirror `TUI.App.owl_puts/1` defensive logging pattern in `Renderer.OwlOutput.owl_puts/1` (currently only catches `:terminated`) — implemented: catches `:error/:exit :terminated` + generic `kind, reason`
- [x] Add a `TUI.Output` / `TUI.RenderTarget` adapter to reduce Owl coupling per ADR-007's "make Owl swappable" intent — implemented: `TUI.Output` behaviour + `OwlOutput` conforming module
- [x] Replace `Task.shutdown(:brutal_kill)` in `Input.terminate/2` with monitor-aware graceful shutdown + bounded fallback — implemented: monitor + `:shutdown` + 3s timeout (code_puppy-057.4)
- [x] Handle string-keyed legacy events in `Renderer.EventMapper.legacy_event_to_canonical/1` (currently atom-keyed only) — implemented: handles both `%{"type" => _}` and `%{type: _}`
- [x] Make `@flush_threshold` configurable in `Renderer` (currently hardcoded at 20 — likely too low for streaming) — implemented: accepted via `:flush_threshold` option in `start_link`
- [x] Align `Input` module docs with implementation OR implement advertised line-editing/history/Ctrl+W/tab-completion features — aligned: docs clarify Input does NOT implement line editing, only history add/dedup/retrieval

**Test quality / drift prevention:**
- [x] Reduce `:sys.get_state/1` reliance in `renderer_test.exs` (drift risk — should test boundary behavior) — resolved: renderer tests use public API queries (`streaming?/2`, `token_count/1`, `all_buffers_flushed?/1`); no `:sys.get_state` calls remain
- [x] Strengthen `markdown_test.exs` beyond `assert is_list(result)` smoke checks — resolved: comprehensive tests with `render_to_string` helper, content assertions, tag checks, unicode/emoji/nil edge cases (7.2KB test file)
- [x] Make `model_selector_test.exs` deterministic — currently passes vacuously when no models configured — resolved: injects 12 `@test_models` into ETS with temp API keys; never passes vacuously (22.6KB test file)
- [x] Tighten config screen test boundaries — currently accepts both success and `write_error` outcomes — resolved: deterministic "set then get" tests, specific error assertions; dual-outcome cases have explicit justification comments

**Plugin / CLI integration (post-prg.1+2 audit):**
- [x] Implement `--continue` session restore — currently parsed but routes to plain interactive mode (`cli.ex` docstring acknowledges) — implemented: `CLI.SessionResume` module (6.4KB) loads newest session into `Agent.State`, then starts REPL with restored `:session_id`; telemetry + test coverage in `session_resume_test.exs`
- [x] Implement `--bridge-mode` runtime effect — implemented via RuntimeSelector (code_puppy-bwt): `--bridge-mode` sets `PUP_RUNTIME=python` for the session, forcing all capabilities to delegate to the Python bridge

**Coverage gaps (no CI gate, but flag for future):**
- [x] `TUI.Widgets.ModelSelector` — was 7.23% coverage — resolved: 22.6KB test file with 12 injected test models, exercises list_models, short_name, context_length, parse_selection, maybe_filter, select/1
- [x] `TUI.Widgets.SessionBrowser` — was 18.75% coverage — resolved: 9.3KB test file covering format_session, timestamps (DateTime/ISO8601/nil/garbage), token formatting (k/M), auto_saved edge cases
- [x] `TUI.Widgets.AgentSelector` — was 21.05% coverage — resolved: 10.1KB test file covering list_agents, slug kebab-case validation, sorting, filtering, module resolution
- [x] `TUI.Input` — was 36.59% coverage — resolved: 9.0KB test file covering lifecycle, history dedup, input forwarding, EOF handling, prompt changes, clear_history
- [x] `TUI.Renderer.EventMapper` — was 45.45% coverage — resolved: 4.2KB test file covering wire-format events, atom-keyed legacy, string-keyed legacy, non-map/nil/empty edge cases

### Phase H: Cutover

> Tracking: epic `code_puppy-djs` (filed 2026-04-29), 8 child tasks: <H.1: `code_puppy-djs.1`>, <H.2: `code_puppy-djs.2`>, <H.3: `code_puppy-djs.3`>, <H.4: `code_puppy-djs.4`>, <H.5: `code_puppy-djs.5`>, <H.6: `code_puppy-djs.6`>, <H.7: `code_puppy-djs.7`>, <H.RT: `code_puppy-bwt`>
> Historical: epic `code_puppy-3f9` (filed 2026-04-25, 7 child tasks)
> Phase H reality audit: [docs/triage/phase-h-reality-audit-2026-04-29.md](docs/triage/phase-h-reality-audit-2026-04-29.md)

- [x] Feature-flag Elixir code paths (code_puppy-djs.4) — implemented: `FeatureFlags` GenServer with ETS-backed flags.json, per-capability toggles, atomic disk persistence
- [x] Gradual rollout per capability (code_puppy-djs.6) — implemented: `Rollout` GenServer with percentage-based routing, `:ets.update_counter` observability, error-rate rollback detection
- [x] Delete Python tree when Elixir is at parity (code_puppy-djs.2) — Categories A, B, D complete (~17.4K LoC removed: api/, state_migration, ttsr, frontend_emitter, tracing_*, auto_test_control, synthetic_status, completion_notifier, render_check, error_logger, example_custom_command, browser/, scheduler/, plugins/scheduler/, scheduler_screen, repo_compass, code_explorer, code_context, code_skeleton); see `docs/triage/djs2-deletion-manifest.md`
- [x] Runtime selector + dual-run router (code_puppy-bwt) — child of code_puppy-djs — implemented: `RuntimeSelector` module with mode/0, select/1, select_with_reason/1, elixir_handles?/1; auto mode routes per-capability via FeatureFlags; `--bridge-mode` now forces PUP_RUNTIME=python
- [x] Implement --continue session restore (code_puppy-djs.5) — implemented: `CLI.SessionResume` module loads newest persisted session into `Agent.State`, then starts REPL with restored `:session_id`
- [x] Implement --bridge-mode runtime effect (code_puppy-djs.3) — done: `--bridge-mode` sets PUP_RUNTIME=python via RuntimeSelector (code_puppy-bwt)
- [x] Update CONTRIBUTING.md (code_puppy-djs.7) — added Phase H runtime routing infrastructure section documenting FeatureFlags, RuntimeSelector, and Rollout

> **Phase H reality audit (code_puppy-djs.1) is ✅ COMPLETE.** See [audit document](docs/triage/phase-h-reality-audit-2026-04-29.md). The audit is separate from djs.4 implementation.

## Phase I: Distributed packs (multi-node Erlang cluster)

> Tracking: code_puppy-yge.2 (research/design branch `feature/yge-2-distributed-packs`)
> Design doc: [docs/distributed-packs.md](docs/distributed-packs.md)

Goal: Enable pack orchestration across multiple Erlang nodes using Erlang
built-in distribution (no external dependencies). A Pack Leader running on
the operator's workstation can dispatch sub-agents to remote worker nodes.

### Phase I.0: Design + prototype (this branch)

- [x] Write comprehensive design document at `docs/distributed-packs.md`
- [x] Create prototype design sketches under `docs/prototypes/pack/` (moved from
      compiled code per critic feedback — see `code_puppy-yge.2` issues)
  - Reference modules: `DistributedSupervisor`, `RemoteNodeSupervisor`,
    `RemoteNodeProxy`, `NodeMonitor`, `NamingService`, `Worker`,
    `Worker.Application`, `SubAgentPool` — all under `docs/prototypes/pack/`
  - Note: Prototypes are **design references only** — not compiled code.
    Phase I.1 will build proper OTP skeletons with tests from the
design doc.

### Phase I.1: Skeleton integration

- [x] Wire `NodeMonitor` + `DistributedSupervisor` into root supervision tree (disabled by default via `packs.distributed.enabled = false`) — implemented: `Pack.NodeMonitor` (371 lines, heartbeat + grace period + telemetry), `Pack.DistributedSupervisor` (DynamicSupervisor with `:via` Registry), `Pack.NamingService` (ETS capability index), conditional startup via `maybe_pack_children/0` in `application.ex`
- [x] Add Registry tables for `:via` tuple routing — implemented: `Pack.Registry` module with `via/1` helper, started as `{Registry, keys: :unique, name: Pack.Registry}` in pack subtree
- [x] Add configuration keys to `puppy.cfg` spec — implemented: `Pack.Config` reads `[packs.distributed]` section (enabled, node_name, cookie, workers, connect_timeout, heartbeat_interval, disconnect_timeout, dispatch_style, sync_timeout)
- [x] Wire telemetry events into the existing `Telemetry` module — already implemented: `Telemetry.DistributedPack` (node lifecycle + dispatch + capability events) + `Telemetry.ClusterDashboard` (aggregation GenServer)

### Phase I.2: Worker-mode application

- [x] Create `CodePuppyControl.Pack.Worker.Application` as a startable OTP app — implemented: lightweight Supervisor with Finch, ProviderRegistry, SubAgentPool, Worker
- [x] Support `--sname` / `--name` + `--cookie` CLI flags for workers — implemented: parser + CLI worker_mode + Node.start/set_cookie integration
- [x] Worker detects and advertises capabilities on leader connect — implemented: Worker monitors :nodeup, casts capabilities to leader NodeMonitor; NodeMonitor registers in NamingService
- [x] Add `/pack cluster` slash command for cluster status/management — implemented: PackCluster module with status/nodes/capabilities subcommands, wired into existing /pack dispatch
- [x] Integration test: one leader + one worker on localhost — implemented: Worker.Application supervisor test + PackCluster command test + parser flag tests

### Phase I.3: Capability-aware dispatch

- [x] Pack Leader can query NamingService for eligible workers — implemented: `Pack.Dispatcher.resolve_target/2` queries `NamingService.find_nodes/1-2` with optional constraints; returns `:local` or `{:remote, node}`
- [x] `cp_invoke_agent("terrier", params, node: :worker@host)` syntax — implemented: `node` parameter added to `CpInvokeAgent` tool schema + `AgentInvocation.invoke/3` opts; string→atom conversion with safety
- [x] Default: dispatch locally (backward compatible) — implemented: when distributed disabled OR no `node:` specified OR no workers available, `Dispatcher` returns `:local` and `AgentInvocation` follows existing `do_invoke` path
- [x] Graceful degradation if no remote workers match — implemented: `Dispatcher.dispatch_remote/5` catches `:exit`, handles timeout, and falls back to local `AgentInvocation.invoke/3` with warning log + telemetry

### Phase I.4: Automatic load balancing

- [x] Round-robin across workers with matching capabilities — implemented: `Pack.LoadBalancer` GenServer with `select_worker/2` round-robin, wired into `Dispatcher.find_available_worker/2` with fallback to NamingService first-match
- [x] Per-worker slot tracking (respects `max_concurrent_runs`) — implemented: LoadBalancer tracks `active_dispatches` vs `max_concurrent` per node; workers at capacity excluded from selection
- [x] Disconnect grace period with in-flight run management — implemented: NodeMonitor `register_run/2` / `unregister_run/2` / `active_runs/1`; grace expiry clears runs + removes from LoadBalancer
- [x] Fallback to local dispatch on remote node failure — implemented: Dispatcher catches `:exit` on LoadBalancer calls, falls back to NamingService first-match, then to local dispatch

### Phase I.5: Production hardening

- [x] TLS for Erlang distribution (`-proto_dist inet_tls`) — implemented: `Pack.TLS` config helper generates `ssl_dist.conf`, VM args, and validates cert files; `Config` extended with `:tls` section
- [x] Ephemeral vs. persistent worker modes — implemented: Worker drain mode (`:drain` cast, reject-while-draining, auto-stop on last run); shutdown announcement to leader via NodeMonitor; ephemeral idle shutdown already in I.2
- [x] Sub-agent result streaming (progress updates during execution) — implemented: `Dispatcher.await_with_progress/7` receive loop handles `{:progress, run_id, payload}` interleaved with result; optional `progress_callback` in dispatch opts; telemetry emission
- [x] Telemetry dashboard for cluster status — implemented: `Pack.ClusterStatus` aggregates all subsystem state into `snapshot/0`; `format/1` rich terminal display; `/pack-cluster` Python slash command via bridge

> **Rollback:** At any phase, set `packs.distributed.enabled = false` and
> the cluster code is a no-op. The existing local pack parallelism behavior
> is preserved.

## Deferred / ideas

- [x] Replace lefthook with Git-native hooks — removed lefthook.yml, native hooks in scripts/git-hooks/, installer at scripts/install-hooks.sh
- [x] Phoenix LiveView admin UI for pack orchestration

## Closed

### bd removal (2026-04-24 — commit `b94b6222`)

- [x] Delete bd tracker from project entirely
- [x] Purge Bloodhound agent
- [x] Rewire pack-leader to git-based coordination
- [x] Clean 1,357 bd-NNN references from 248 files
