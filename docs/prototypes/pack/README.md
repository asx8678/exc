# Distributed Packs — Prototype Reference

## Status: Design Reference Only 🚧

These `.ex` files are **prototype design sketches** moved from compiled code per critic feedback on `feature/yge-2-distributed-packs` (issue `code_puppy-yge.2`).

## Known Issues (why these are NOT compiled code)

The prototype modules were written as exploratory design sketches and contain known OTP/runtime issues:

- **Invalid GenServer naming** — `{@pack_worker_name, node_name}` tuple is not a valid `:via` tuple
- **Invalid ETS match specs** — `NamingService` uses incorrect match spec patterns
- **DynamicSupervisor misuse** — using child IDs instead of PIDs for operation
- **Missing Registry dependencies** — references `Registry` modules not yet added
- **Wrong node event message shapes** — `NodeMonitor` emits events in incorrect format
- **No test coverage** — zero tests exist for any module

## To Phase I.1 Implementers

Do **NOT** copy these files directly into `lib/`. Instead:

1. Read `docs/distributed-packs.md` (the comprehensive design doc — 793 lines)
2. Build proper OTP skeletons from scratch, following the design doc
3. Include full test coverage (unit + integration)
4. Follow project conventions: Mox-based mocking, behaviours for swapability, `@impl true` on callbacks
5. All new modules must compile under `--warnings-as-errors` and pass Credo/Dialyzer

## File Index

| File | Purpose |
|------|---------|
| `distributed_supervisor.ex` | DynamicSupervisor managing per-node children |
| `remote_node_supervisor.ex` | One-for-one supervisor per remote node |
| `remote_node_proxy.ex` | GenServer tracking connection state + dispatching |
| `node_monitor.ex` | Heartbeat loop for node up/down/reconnect |
| `naming_service.ex` | ETS-backed capability index for worker selection |
| `worker.ex` | Worker-side GenServer accepting leader dispatch |
| `worker/application.ex` | Lightweight OTP application for worker nodes |
| `sub_agent_pool.ex` | DynamicSupervisor for sub-agent processes |

See `docs/distributed-packs.md` for the full design.
