# ADR-007: TUI Framework — Owl over Ratatouille

## Status

**ACCEPTED** (2026-05-28)

## Context

Phase G of the Python-to-Elixir migration (ADR-004) requires a TUI layer
for the Elixir CLI. The ROADMAP explicitly flags the framework decision:

> TUI in Elixir (Owl? Ratatouille?)

Two candidate frameworks exist in the Elixir ecosystem:

### Owl

A lightweight terminal toolkit providing composable primitives:
`Owl.Data` (ANSI-styled fragments), `Owl.IO` (TTY-aware output),
`Owl.Spinner`, `Owl.ProgressBar`, `Owl.LiveScreen` (live-updating
blocks), `Owl.Box`, and `Owl.Table`.

Owl is **not** a full TUI framework — it does not manage layout,
focus, or application lifecycle. It is a rendering and interaction
toolkit that composes with standard GenServer/OTP patterns.

### Ratatouille

A full-featured TUI framework modelled after Elm / The Elm Architecture:
`init/1 → update/2 → render/1`. It provides terminal layout
management (panels, borders, flex), keyboard event handling, and
a managed application lifecycle.

Ratatouille abstracts the terminal into a declarative view layer
with diff-based rendering and cursor management.

### Existing Investment

The Elixir TUI layer (`lib/code_puppy_control/tui/`) already contains
**13 modules** built on Owl:

| Module | Role | Owl Dependencies |
|--------|------|-------------------|
| `TUI.App` | Screen navigation GenServer | `Owl.LiveScreen`, `Owl.IO.puts` |
| `TUI.Screen` | Screen behaviour | `Owl.IO.puts` |
| `TUI.Renderer` | Streaming event renderer | `Owl.Data.tag`, `Owl.Spinner`, `Owl.IO.puts` |
| `TUI.Markdown` | Markdown → Owl.Data | `Owl.Data.tag` |
| `TUI.Syntax` | Syntax highlighting | `Owl.Data.tag` |
| `TUI.Progress` | Spinner / progress bar | `Owl.Spinner`, `Owl.ProgressBar`, `Owl.IO.puts` |
| `TUI.Prototype` | Go/No-Go gate demo | Raw ANSI (no Owl) |
| `Screens.Chat` | Chat interface | `Owl.Box`, `Owl.Data.tag` |
| `Screens.Config` | Config viewer/editor | `Owl.Box`, `Owl.Table`, `Owl.Data.tag` |
| `Screens.Help` | Help overlay | `Owl.Box`, `Owl.Table`, `Owl.Data.tag` |
| `Widgets.AgentSelector` | Agent picker | `Owl.IO.select`, `Owl.Box`, `Owl.Table` |
| `Widgets.ModelSelector` | Model picker | Same as AgentSelector |
| `Widgets.SessionBrowser` | Session list | Same as AgentSelector |

These modules represent **~130 KB** of working, tested code with
**17 passing test modules**. Switching to Ratatouille would require
rewriting all 13 modules from scratch.

## Decision

**Choose Owl** as the TUI framework for Code Puppy's Elixir CLI.

### D1: Owl's imperative/streaming model matches Code Puppy's architecture

Code Puppy's primary rendering pattern is **streaming LLM output** —
text deltas arrive incrementally over SSE and must be flushed to the
terminal as they arrive. This is a push-based, imperative pattern:

```
EventBus → Renderer.handle_cast → Owl.IO.puts / Owl.LiveScreen.update
```

Ratatouille's Elm Architecture (`update → model → view`) assumes the
application **pulls** from a model to produce a view on each tick.
Adapting streaming LLM output to this pattern would require either:

1. **Batching deltas into the model and triggering re-renders** —
   introduces latency and complexity for no gain
2. **Side-stepping the architecture with `Cmd` hacks** —
   undermines the framework's guarantees

Owl's `LiveScreen` blocks are a natural fit: the Renderer pushes
deltas directly into a live block, and Owl handles the diff-based
terminal update. No model/view indirection needed.

### D2: Zero rewrite cost — the code already exists

13 modules, 17 test suites, ~130 KB of working code already use Owl.
Switching to Ratatouille would:

| Factor | Cost |
|--------|------|
| Rewrite 13 modules | ~2-3 weeks of work |
| Port 17 test suites | ~1 week |
| New `Screen` behaviour | Must redesign from `handle_input → {:ok, state}` to `update → model` |
| Widget re-architecture | Ratatouille uses `Element` trees, not `Owl.Data` fragments |
| Regression risk | All existing TUI functionality must be re-validated |

This is a **net-negative** investment for Phase G, whose goal is
"working TUI" not "perfect TUI framework."

### D3: Owl composes with OTP — Ratatouille replaces it

Owl is a **toolkit**, not a **framework**. It composes with standard
OTP patterns:

- `TUI.App` is a GenServer with a screen stack
- `TUI.Renderer` is a GenServer subscribed to PubSub
- Both use Owl for **output only** — lifecycle, state, and concurrency
  are standard OTP

Ratatouille is an **application framework** that owns the event loop,
rendering cycle, and lifecycle. Mixing Ratatouille with OTP
supervision requires workarounds (e.g. starting Ratatouille as a
supervised child with `Ratatouille.run/2`).

For Code Puppy, where the TUI is one subsystem among many (agent
loop, tool runner, Python worker, MCP), keeping the TUI as a plain
OTP citizen is architecturally cleaner.

### D4: Ratatouille's strengths are not needed yet

Ratatouille excels at:

- **Complex layout management** (split panes, borders, flex)
- **Keyboard event handling** (arrow keys, modifier combos)
- **Declarative rendering with diff-based updates**

Code Puppy's current TUI needs are simpler:

- Streaming text output (Owl `LiveScreen`)
- Simple screen navigation (Owl + GenServer stack)
- Basic input (`Owl.IO.select`, `IO.gets`)
- Spinners and progress bars (Owl primitives)

If Code Puppy later needs a full-featured terminal UI (e.g. a
multi-panel IDE-like interface), Ratatouille or a similar framework
should be reconsidered. But for Phase G's requirements, Owl is
sufficient and appropriate.

### D5: Maintenance and ecosystem health

| Factor | Owl | Ratatouille |
|--------|-----|-------------|
| Latest release | 0.12.x (active) | 0.5.x (less frequent) |
| GitHub stars | ~800+ | ~700+ |
| Recent commits | Active (2025-2026) | Sporadic |
| Dependencies | None (pure Elixir) | `tea_buf` (NIF) |
| Hex downloads | Higher | Lower |

Owl is lighter-weight (no NIF dependencies) and more actively
maintained. Ratatouille's `tea_buf` NIF dependency can cause
cross-compilation issues with Burrito packaging.

## Implementation Specification

### TUI Architecture (Owl-based)

```
┌──────────────────────────────────────────────┐
│                TUI.Supervisor                 │
│  ┌─────────┐  ┌──────────┐  ┌────────────┐  │
│  │   App   │  │ Renderer │  │  Launcher   │  │
│  │ (GenServer)│ │(GenServer)│ │(entry point)│ │
│  └────┬────┘  └────┬─────┘  └────────────┘  │
│       │             │                         │
│  ┌────┴────┐   PubSub subscription            │
│  │ Screens │   (EventBus)                     │
│  │ (behaviour)                                │
│  └─────────┘                                  │
└──────────────────────────────────────────────┘
```

### Key Components

| Component | Module | Responsibility |
|-----------|--------|---------------|
| Supervisor | `TUI.Supervisor` | Own App + Renderer processes |
| App | `TUI.App` | Screen stack, navigation, render cycle |
| Renderer | `TUI.Renderer` | Streaming LLM output via Owl |
| Launcher | `TUI.Launcher` | Entry point, env-var gating, startup |
| Theme | `TUI.Theme` | Centralized brand palette |
| Input | `TUI.Input` | Non-blocking line reading |
| Screen | `TUI.Screen` | Behaviour for screen modules |

### Additions to existing code

| New Module | Purpose |
|------------|---------|
| `TUI.Supervisor` | OTP supervisor for TUI processes |
| `TUI.Launcher` | Env-gated entry point (`CODE_PUPPY_TUI=1`) |
| `TUI.Theme` | Centralized color/style constants |
| `TUI.Input` | Non-blocking input with history |

These modules **extend** the existing Owl-based foundation without
modifying any existing TUI code.

## Alternatives Considered

### A1: Ratatouille (full TUI framework)

**Rejected**: Requires rewriting all 13 existing modules. The Elm
Architecture is a poor fit for Code Puppy's push-based streaming
model. Zero existing code is reusable. See D1–D4 above.

### A2: Raw ANSI escape codes (no framework)

**Rejected**: The `TUI.Prototype` module demonstrates this is
possible for a demo, but production code needs spinners, progress
bars, tables, live blocks, and styled data. Reimplementing these
in raw ANSI is a maintenance burden with no upside.

### A3: Burrito + Ratatouille (NIF-free path)

**Rejected**: Even if Ratatouille's NIF dependency were removed,
the architectural mismatch (Elm Architecture vs streaming model)
remains. The rewrite cost is not justified.

### A4: Deferred decision (no ADR, continue with Owl ad-hoc)

**Rejected**: Phase G explicitly requires an ADR before TUI code
begins. The existing Owl code was written pre-ADR as prototype
work. Formalizing the decision prevents future "should we switch?"
debates.

## Consequences

### Positive

- **Zero rewrite cost** — all existing TUI code continues unchanged
- **Streaming-native** — Owl's LiveScreen blocks match Code Puppy's
  push-based rendering model exactly
- **OTP composable** — TUI processes are standard GenServers, testable
  and supervisable without framework lock-in
- **Lightweight** — Owl adds ~0 dependencies (pure Elixir), compatible
  with Burrito packaging
- **Familiar API** — team already knows Owl; no learning curve

### Negative

- **No complex layout** — Owl lacks Ratatouille's flex/panel layout.
  Multi-panel UIs (e.g. sidebar + editor + output) would need manual
  ANSI positioning or a future migration.
- **Manual cursor management** — Owl doesn't abstract cursor movement.
  Advanced cursor patterns (text input with editing) need custom code
  in `TUI.Input`.
- **Feature ceiling** — If Code Puppy needs a full IDE-like terminal
  interface, Owl may not suffice. Mitigation: the ADR can be
  revisited with a new ADR if requirements change.

### Risk Mitigation

The biggest risk is **feature ceiling** — Owl may not support future
TUI requirements. Mitigation:

1. The `Screen` behaviour abstracts rendering — screens produce
   `Owl.Data.t()`, not raw ANSI. If we switch frameworks later,
   only `TUI.App.render_active/1` and screen `render/1` callbacks
   need adaptation.
2. `TUI.Input` isolates input handling — switching to Ratatouille's
   event model only requires changing this module.
3. This ADR explicitly documents the trade-off so a future ADR-008
   can revisit the decision with new data.

## CI Gates

| Gate | Test | Rationale |
|------|------|-----------|
| GATE-G1-1 | `TUI.Supervisor` starts App + Renderer | Proves supervision wiring |
| GATE-G1-2 | `TUI.Launcher` respects `CODE_PUPPY_TUI=1` | Proves env-var gating |
| GATE-G1-3 | `TUI.Theme` returns valid Owl color atoms | Proves theme consistency |
| GATE-G1-4 | `TUI.Input` reads lines non-blocking | Proves non-blocking input |
| GATE-G1-5 | Existing TUI tests still pass | Proves no regression |
| GATE-G1-6 | `mix format` clean | Proves code quality |

## References

- [ADR-004](ADR-004-python-to-elixir-migration-strategy.md) — Phase G: CLI + UI
- [ROADMAP.md](../../ROADMAP.md) — Phase G tracking
- [TUI_CLI_AUDIT.md](../TUI_CLI_AUDIT.md) — Python TUI deprecation audit
- [Owl on Hex](https://hex.pm/packages/owl)
- [Ratatouille on Hex](https://hex.pm/packages/ratatouille)
- Existing TUI code: `lib/code_puppy_control/tui/`

---

**Decision Date**: 2026-05-28
**Decision Maker**: Code Puppy Migration Team
**Issue**: code_puppy-prg.3
**Status**: Accepted
