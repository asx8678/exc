# Python Singleton State Audit

> **Purpose**: Document all global/singleton state in Python codebase to inform Elixir migration.
> **Date**: 2026-04-14
> **Issue**: python-singleton-audit

## Executive Summary

The codebase uses **7 key singletons** with module-level state and double-checked locking:

| Module | Singleton | Lock Type | Async | Risk | Elixir Target |
|--------|-----------|-----------|-------|------|---------------|
| `agent_manager.py` | `_state` dataclass | 2× `threading.Lock` | No | ✅ Low | Registry + GenServer |
| `messaging/bus.py` | `_global_bus` | Lock + Event + Queue | Yes | ✅ Low | Phoenix.PubSub |
| `adaptive_rate_limiter.py` | `_state` class | `asyncio.Lock` + Condition | Yes | ⚠️ Med | GenServer + ETS |
| `concurrency_limits.py` | 3× semaphores | `threading.Lock` (DCL) | Yes | ✅ Low | Connection pools |
| `run_limiter.py` | `_limiter_instance` | Lock + ContextVar | Yes | ✅ Low | GenServer + Registry |
| `history_buffer.py` | `_global_buffer` | `threading.Lock` | No | ✅ Low | ETS / EventStore |
| `mcp_/manager.py` | `_manager_instance` | `threading.Lock` | Yes | ⚠️ Med | DynamicSupervisor |

---

## Detailed Audit

### 1. Agent Manager (`code_puppy/agents/agent_manager.py`)

#### Singleton Structure
```python
@dataclass
class AgentManagerState:
    agent_registry: dict[str, AgentInfo] = field(default_factory=dict)
    agent_histories: dict[str, list[ModelMessage]] = field(default_factory=dict)
    current_agent: BaseAgent | None = None
    registry_populated: bool = False
    session_agents_cache: dict[str, str] = field(default_factory=dict)
    session_file_loaded: bool = False

_state = AgentManagerState()
_SESSION_LOCK = threading.Lock()
_REGISTRY_LOCK = threading.Lock()
```

#### Mutating Operations
| Operation | Lock Used | Effect |
|-----------|-----------|--------|
| `_discover_agents()` | `_REGISTRY_LOCK` | Populates registry, sets `registry_populated=True` |
| `set_current_agent()` | `_SESSION_LOCK` | Writes `current_agent`, cache, histories |
| `refresh_agents()` | `_REGISTRY_LOCK` | Clears and re-discovers registry |
| `clone_agent()` | `_REGISTRY_LOCK` | Adds to registry + filesystem |

#### Elixir Mapping
```elixir
# Registry for agent lookup
{:via, Registry, {AgentRegistry, agent_name}}

# GenServer for agent state
defmodule CodePuppyControl.AgentManager do
  use GenServer
  
  defstruct [:current_agent, :session_cache, histories: %{}]
  
  def handle_call(:get_current, _from, state) do
    {:reply, state.current_agent, state}
  end
end
```

---

### 2. Message Bus (`code_puppy/messaging/bus.py`)

#### Singleton Structure
```python
class MessageBus:
    _outgoing: asyncio.Queue[AnyMessage]      # Agent→UI
    _incoming: asyncio.Queue[AnyCommand]      # UI→Agent
    _startup_buffer: deque[AnyMessage]        # Pre-renderer buffer
    _pending_requests: dict[str, asyncio.Future]  # Prompt responses
    _current_session_id: str | None
    _lock: threading.Lock
    _renderer_event: threading.Event          # Lock-free fast path

_global_bus: MessageBus | None = None
_bus_lock = threading.Lock()
```

#### Mutating Operations
| Operation | Lock Used | Effect |
|-----------|-----------|--------|
| `emit()` | `_lock` | Appends to buffer or queue |
| `provide_response()` | `_lock` | Resolves Future or enqueues |
| `mark_renderer_active()` | `_lock` + `_renderer_event` | Flips flag, drains buffer |
| `set_session_context()` | `_lock` | Sets `_current_session_id` |

#### Elixir Mapping
```elixir
# Phoenix PubSub for event distribution
Phoenix.PubSub.broadcast(CodePuppyControl.PubSub, "session:#{session_id}", event)

# GenServer for pending request tracking
defmodule CodePuppyControl.RequestTracker do
  use GenServer
  
  def handle_call({:await_response, prompt_id}, from, state) do
    # Store {prompt_id, from} and reply later
    {:noreply, Map.put(state.pending, prompt_id, from)}
  end
  
  def handle_cast({:provide_response, prompt_id, response}, state) do
    case Map.pop(state.pending, prompt_id) do
      {nil, state} -> {:noreply, state}
      {from, state} -> 
        GenServer.reply(from, response)
        {:noreply, state}
    end
  end
end
```

---

### 3. Adaptive Rate Limiter (`code_puppy/adaptive_rate_limiter.py`)

#### Singleton Structure
```python
@dataclass
class ModelRateLimitState:
    current_limit: float
    active_count: int = 0
    condition: asyncio.Condition | None = None
    circuit_state: CircuitState = CircuitState.CLOSED
    request_queue: asyncio.Queue | None = None
    # ... counters and timestamps

class _RateLimiterState:
    model_states: dict[str, ModelRateLimitState]
    lock: asyncio.Lock | None = None
    recovery_task: asyncio.Task | None = None
    circuit_tasks: set[asyncio.Task]
    # ... config fields

_state = _RateLimiterState()
```

#### Risk: Unprotected Dict Mutations
The `model_states` dict is accessed from multiple async contexts. While `asyncio.Lock` protects some operations, individual dict reads rely on GIL.

#### Elixir Mapping
```elixir
# ETS for per-model state (lock-free reads)
:ets.new(:rate_limits, [:named_table, :public, read_concurrency: true])

# GenServer for mutations
defmodule CodePuppyControl.RateLimiter do
  use GenServer
  
  def handle_call({:acquire_slot, model}, from, state) do
    case check_limit(state, model) do
      :ok -> 
        new_state = increment_active(state, model)
        {:reply, :ok, new_state}
      :wait ->
        # Add to waiters, reply later
        {:noreply, add_waiter(state, model, from)}
    end
  end
end
```

---

### 4. Concurrency Limits (`code_puppy/concurrency_limits.py`)

#### Singleton Structure
```python
class TrackedSemaphore:
    _sem: asyncio.Semaphore
    _value: int              # Counter
    _lock: threading.Lock    # Guards counter

_file_ops_semaphore: TrackedSemaphore | None = None
_api_calls_semaphore: TrackedSemaphore | None = None
_tool_calls_semaphore: TrackedSemaphore | None = None
_semaphore_init_lock = threading.Lock()
```

#### Elixir Mapping
```elixir
# Poolboy or custom semaphore GenServer
defmodule CodePuppyControl.ConcurrencyGate do
  use GenServer
  
  defstruct [:limit, :active, waiters: :queue.new()]
  
  def handle_call(:acquire, from, %{active: a, limit: l} = state) when a < l do
    {:reply, :ok, %{state | active: a + 1}}
  end
  
  def handle_call(:acquire, from, state) do
    {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
  end
end
```

---

### 5. Run Limiter (`code_puppy/plugins/pack_parallelism/run_limiter.py`)

#### Singleton Structure
```python
class RunLimiter:
    _async_sem: asyncio.Semaphore
    _sync_sem: threading.Semaphore
    _state_lock: threading.Lock
    _async_active: int
    _sync_active: int
    _async_deficit: int      # Shrink tracking
    _sync_deficit: int

_limiter_instance: RunLimiter | None = None
_limiter_lock = threading.Lock()
_reentrancy_depth = contextvars.ContextVar[int]("run_limiter_depth", default=0)
```

#### Notable: ContextVar for Reentrancy
```python
# Allows nested agent calls without deadlock
if _reentrancy_depth.get() > 0:
    return  # Already have a slot from outer call
_reentrancy_depth.set(_reentrancy_depth.get() + 1)
```

#### Elixir Mapping
```elixir
# Process dictionary for reentrancy (each process has own dict)
defmodule CodePuppyControl.RunLimiter do
  def acquire do
    case Process.get(:run_limiter_depth, 0) do
      0 -> 
        # Actually acquire from GenServer
        GenServer.call(__MODULE__, :acquire)
        Process.put(:run_limiter_depth, 1)
      n -> 
        # Reentrant, already have slot
        Process.put(:run_limiter_depth, n + 1)
        :ok
    end
  end
end
```

---

### 6. History Buffer (`code_puppy/messaging/history_buffer.py`)

#### Singleton Structure
```python
class SessionHistoryBuffer:
    _history: dict[str, deque[dict]]  # session_id → events
    _last_access: dict[str, float]    # TTL tracking
    _lock: threading.Lock
    _maxlen: int
    _ttl_seconds: int

_global_buffer: SessionHistoryBuffer | None = None
_buffer_lock = threading.Lock()
```

#### Elixir Mapping
```elixir
# ETS with TTL cleanup via periodic task
:ets.new(:session_history, [:named_table, :bag])

defmodule CodePuppyControl.HistoryBuffer do
  use GenServer
  
  def init(_) do
    schedule_cleanup()
    {:ok, %{}}
  end
  
  def handle_info(:cleanup, state) do
    cutoff = System.monotonic_time(:second) - @ttl_seconds
    # Delete old entries from ETS
    schedule_cleanup()
    {:noreply, state}
  end
end
```

---

### 7. MCP Manager (`code_puppy/mcp_/manager.py`)

#### Singleton Structure
```python
class MCPManager:
    registry: ServerRegistry
    status_tracker: ServerStatusTracker
    _managed_servers: dict[str, ManagedMCPServer]
    _pending_start_tasks: dict
    _pending_stop_tasks: dict

_manager_instance: MCPManager | None = None
_manager_lock = threading.Lock()
```

#### Risk: Unprotected Dict Mutations
`_managed_servers` is mutated from sync and async paths without a lock, relying on GIL.

#### Elixir Mapping
```elixir
# DynamicSupervisor for server processes
defmodule CodePuppyControl.MCP.Supervisor do
  use DynamicSupervisor
  
  def start_server(server_config) do
    spec = {CodePuppyControl.MCP.Server, server_config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end

# Registry for server lookup
{:via, Registry, {MCP.ServerRegistry, server_name}}

# Per-server GenServer
defmodule CodePuppyControl.MCP.Server do
  use GenServer, restart: :transient
  
  def init(config) do
    # Start MCP server process via Elixir port
    {:ok, %{config: config, status: :starting}}
  end
end
```

---

## Key Patterns for Elixir Migration

### 1. Double-Checked Locking → Lazy GenServer Start
Python:
```python
if _instance is None:
    with _lock:
        if _instance is None:
            _instance = create()
```

Elixir:
```elixir
# Start in supervision tree, always available
children = [
  {MyGenServer, []}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### 2. threading.Lock → GenServer Serialization
Python locks serialize mutations. In Elixir, GenServer `handle_call` is inherently serialized.

### 3. asyncio.Condition → GenServer Reply Later
Python:
```python
async with condition:
    await condition.wait_for(predicate)
```

Elixir:
```elixir
def handle_call(:wait, from, state) do
  if predicate(state) do
    {:reply, :ok, state}
  else
    {:noreply, add_waiter(state, from)}
  end
end
```

### 4. ContextVar → Process Dictionary
Python's `contextvars` are per-task. Elixir's process dictionary is per-process (equivalent for our use).

### 5. Module-Level State → ETS + GenServer
- **Read-heavy**: Use ETS with `read_concurrency: true`
- **Write-heavy**: Use GenServer
- **Both**: ETS for reads, GenServer for writes

---

## Migration Priority

| Priority | Module | Reason |
|----------|--------|--------|
| 1 | `messaging/bus.py` | Core event distribution, enables PubSub |
| 2 | `agent_manager.py` | Session/agent tracking, enables Registry |
| 3 | `run_limiter.py` | Admission control, blocks orchestration |
| 4 | `mcp_/manager.py` | Server lifecycle, enables supervision |
| 5 | `adaptive_rate_limiter.py` | Rate limiting, can stay Python initially |
| 6 | `concurrency_limits.py` | Simple semaphores, can stay Python initially |
| 7 | `history_buffer.py` | Event replay, moves with PubSub |

---

## Wire Protocol Implications

Each singleton exposes operations that become protocol messages:

### Agent Manager Protocol
```json
{"type": "register_run", "run_id": "...", "agent_name": "...", "session_id": "..."}
{"type": "run_status", "run_id": "..."}
{"type": "cancel_run", "run_id": "..."}
```

### Message Bus Protocol
```json
{"type": "emit", "session_id": "...", "event": {...}}
{"type": "subscribe", "session_id": "..."}
{"type": "provide_response", "prompt_id": "...", "response": "..."}
```

### Run Limiter Protocol
```json
{"type": "acquire_slot", "run_id": "...", "reentrant": true}
{"type": "release_slot", "run_id": "..."}
{"type": "update_limit", "new_limit": 6}
```

---

## Next Steps

1. Finalize protocol spec based on these operations
2. Bootstrap Elixir with Registry + PubSub
3. Implement Agent Registry GenServer
4. Implement PubSub event distribution
