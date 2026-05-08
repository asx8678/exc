# Agent Runtime — Design Notes

## Architecture Overview

The agent runtime replaces pydantic-ai's `Agent.run()` loop with an Elixir-native
OTP design. The core insight: **the Python loop is fundamentally a state machine
orchestrating LLM calls and tool dispatch** — which maps cleanly to a GenServer
driving a pure state struct.

Python's `base_agent.py` (2901 lines, 89 methods) has been decomposed into
focused concern modules, each ≤600 lines:

| Concern Module | Python methods ported | Responsibility |
|---|---|---|
| `Agent.Behaviour` | name, system_prompt, allowed_tools, model_preference, display_name, description, on_tool_result, on_before_run, on_after_run | Agent contract |
| `Agent.Loop` | run_with_mcp, run_agent_task | Turn orchestration GenServer |
| `Agent.Turn` | (state machine) | Pure turn state transitions |
| `Agent.State` | message_history, hash_message, set/clear/append/extend | Message history GenServer |
| `Agent.ToolCallTracker` | _collect_tool_call_ids, has_pending_tool_calls, prune_interrupted_tool_calls, _is_tool_call_part, _is_tool_return_part, find_safe_split_index | Tool call ID tracking & pruning |
| `Agent.MessageProcessor` | ensure_history_ends_with_request, filter_huge_messages, message_history_processor, message_history_accumulator, truncation | History processing & filtering |
| `Agent.BudgetEnforcer` | _check_token_budgets, _check_context_budget_before_send, estimate_context_overhead_tokens | Token budget & context enforcement |
| `Agent.Lifecycle` | _load_model_with_fallback, load_puppy_rules, load_mcp_servers, reload_mcp_servers, model_preference pack resolution, prompt assembly | Model resolution & prompt construction |
| `Agent.Events` | (event builders) | Event type definitions |
| `Agent.LLMAdapter` | (bridge) | LLM provider contract translation |
| `Agent.ResponseValidator` | (validation) | Structured output validation |
| `Agent.RunContext` | RunContext port | Tool dependency injection |
| `Agent.RunUsage` | RunUsage port | LLM usage tracking |
| `Agent.UsageLimits` | UsageLimits port | Token/request budgeting |

```
┌─────────────────────────────────────────────────────────────┐
│ Agent.Loop (GenServer) │
│ │
│ ┌──────────┐ ┌─────────────┐ ┌───────────────────┐ │
│ │ Turn n │───→│ LLM Call │───→│ Tool Dispatch │──┤
│ │ (pure │ │ (streaming) │ │ (parallel TBD) │ │
│ │ state) │←───│ │←───│ │←─┤
│ └──────────┘ └─────────────┘ └───────────────────┘ │
│ │ │
│ ▼ │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ EventBus (PubSub + EventStore) │ │
│ └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Why a Pure State Machine for Turns?

The `Turn` module is **pure data + transition functions** — no processes, no side
effects. This was a deliberate choice:

1. **Testability**: Turn transitions can be tested exhaustively without mocking
   or process setup. Property-based tests validate all valid paths through the
   state machine.

2. **Determinism**: Given the same sequence of transitions, `Turn` always produces
   the same result. No race conditions, no hidden state.

3. **Separation of concerns**: `Turn` handles the "what" (valid states and
   transitions). `Loop` handles the "how" (LLM calls, tool dispatch, events).

4. **Debugging**: Turn state can be inspected at any point without triggering
   side effects. The `summary/1` function provides a clean view.

## State Machine Design

```
idle ──→ calling_llm ──→ streaming ──→ tool_calling ──→ tool_awaiting ──→ done
              │ │ │ │
              └────────────────┴───────────────┴───────────────┘
                                      │
                                    error
```

### Why these specific states?

- **`idle`**: Clean starting point. Forces explicit `start_llm_call` transition.
- **`calling_llm`**: Separate from `streaming` because the LLM call setup
  (building context, resolving model) happens before tokens arrive.
- **`streaming`**: Token accumulation happens here. Tool calls are recorded
  but not yet dispatched.
- **`tool_calling`**: Explicit state for "we have tool calls to dispatch."
  Makes it clear we're in tool-handling territory.
- **`tool_awaiting`**: Distinct from `tool_calling` because all calls have been
  dispatched and we're collecting results. This matters when tools run
  concurrently (future enhancement).
- **`done`**: Terminal state. Turn completed normally.
- **`error`**: Terminal state. Something went wrong.

### Why not simpler?

A two-state model (active/done) would lose the ability to:
- Validate transitions at each stage
- Emit specific events at each phase
- Handle the tool_calling → tool_awaiting distinction (important for future
  concurrent tool dispatch)
- Debug where a turn got stuck

## Integration with Existing Modules

### EventBus (reused, not duplicated)

Agent events are published via `CodePuppyControl.EventBus.broadcast_event/2`.
This means:
- Events go to PubSub (for real-time subscribers)
- Events go to EventStore (for replay to late-joining subscribers)
- Events include run_id/session_id for topic routing

Agent event types use `agent_` prefix to avoid collisions with existing event
types like `text`, `tool_result`, etc.

### Run.Supervisor (reused, not duplicated)

Agent.Loop processes are started under the existing `Run.Supervisor`
DynamicSupervisor. The registry key is `{:agent_loop, run_id}` to distinguish
from `{:run_state, run_id}` used by `Run.State`.

This means:
- No new supervisor needed
- Run lifecycle management (listing, termination) works out of the box
- The supervision strategy is inherited (one_for_one, high restart tolerance)

### Run.State (not directly coupled)

`Run.State` tracks run lifecycle for the Python worker path. The agent loop
has its own state management via the `@state` struct. These are intentionally
separate — the Python integration is being phased out.

Future work could unify them, but premature abstraction here would couple us
to the Python architecture we're replacing.

## LLM Behaviour (Placeholder)

The `Agent.LLM` behaviour defines the interface that `CodePuppyControl.LLM` will implement. Key design decisions:

- **`stream_chat/4` callback**: Takes messages, tools, opts, and a callback
  function. The callback receives `{:text, chunk}` and `{:tool_call, name, args, id}`
  events.
- **Synchronous return**: The callback is for streaming side-effects (event
  emission). The return value includes the final accumulated response.
- **No pydantic-ai concepts**: No `ModelMessage`, no `RunContext`, no `UsageLimits`.
  Just messages, tools, and a callback.

## Tool Dispatch (Placeholder)

Current implementation uses a simple `Module.function/1` convention:
- Tool `:file_read` maps to `Tool.FileRead.execute/1`
- Tools must define `execute/1` returning `{:ok, result}` | `{:error, reason}`

This is intentionally simple. A future update will build the proper tool registry with:
- Dynamic tool registration
- Tool metadata (description, schema)
- Tool middleware (auth, rate limiting)
- Tool discovery from MCP servers

## Event Types

All agent events use `agent_` prefix:

| Event | Type String | When |
|----------------------------|------------------------------|------------------------------|
| Turn started | `agent_turn_started` | Before LLM call |
| LLM stream chunk | `agent_llm_stream` | During token streaming |
| Tool call dispatched | `agent_tool_call_start` | Before tool execution |
| Tool call completed | `agent_tool_call_end` | After tool execution |
| Turn ended | `agent_turn_ended` | After turn completes |
| Run completed | `agent_run_completed` | Run finished normally |
| Run failed | `agent_run_failed` | Run failed with error |

Events include `run_id`, `session_id`, and `timestamp` (inherited from
EventBus schema).

## Concurrency Model

- **One Loop process per run**: GenServer, so single-threaded within a run.
  This is correct — a run has a linear conversation history.
- **Tool calls dispatched sequentially**: For now. Future enhancement can
  dispatch independent tools concurrently using `Task.async_stream`.
- **Turn state is immutable**: Each turn creates a new `Turn` struct. The
  Loop's `@state` accumulates across turns.

## What's Explicitly Deferred

| Feature | Ticket | Why deferred |
|---------------------|----------|-----------------------------------------------|
| Tool registry | | Simple module lookup sufficient for Phase 1 |
| Rate limiting | | Option plumbed through, no enforcement yet |
| Token ledger | | Just counting turns + rough usage |
| Concurrent tools | TBD | Sequential dispatch is simpler to reason about|
| Model pack resolver | TBD | Falls back to hardcoded model name |
| Message compaction | TBD | Python-side feature, not yet ported |
| MCP tool discovery | TBD | Depends on MCP module being fully ported |

## Testing Strategy

- **turn_test.exs**: Pure state machine tests + property-based path validation
- **events_test.exs**: Event builder tests + JSON serialization roundtrip
- **loop_test.exs**: Mock LLM and tool for integration-style tests

The mock LLM (`MockLLM`) uses `Agent` for state, making it trivially simple
to configure per-test responses. Tests verify event emission by subscribing
to the run's PubSub topic.
