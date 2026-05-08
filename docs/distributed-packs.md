# Distributed Packs: Multi-Node Erlang Cluster for Pack Orchestration

> **Status:** Design / Research
> **Author:** Elixir Programmer
> **Branch:** `feature/yge-2-distributed-packs`
> **Related:** [ROADMAP.md](../ROADMAP.md) → Deferred / ideas → Distributed packs
> **Spec refs:** This document extends the single-node pack architecture defined
> in existing modules under `lib/code_puppy_control/agents/pack/` and
> `lib/code_puppy_control/plugins/pack_parallelism/`.

---

## 1. Motivation

Code Puppy currently runs as a **single-node OTP application**. The Pack Leader
orchestrates parallel work by delegating sub-agents (retriever, shepherd,
terrier, watchdog) on the **same node** — they share the same Erlang VM, the
same file system, the same SQLite database, and the same credentials.

This works well for a single developer workstation, but breaks down when:

- A team wants to share a **pool of worker nodes** (e.g., dedicated test runners,
  review stations, or build machines).
- A pack needs to run a sub-agent with **different environment characteristics**
  (e.g., a Linux build node from a macOS dev machine).
- A user wants to **offload compute-heavy work** (e.g., running full test suites,
  type-checking with Dialyzer) to a remote beefier machine.
- The operator wants **resilience** — if the leader node crashes, a follower
  should be able to pick up the pack's state.

**The goal:** Enable Pack Leaders to transparently dispatch sub-agents to
remote Erlang nodes using Erlang's built-in distribution protocol — no external
dependencies, no message brokers, no Kubernetes.

---

## 2. Erlang Distribution Primer

Erlang distribution provides everything we need natively:

| Primitive | Purpose |
|-----------|---------|
| `Node.connect/1` | Establish a connection to a remote node |
| `Node.spawn/2` | Spawn a process on a remote node |
| `Node.spawn_link/2` | Spawn and link to a remote process |
| `Node.monitor/2` | Subscribe to node-status changes |
| `Node.list/0` | List all connected nodes |
| `Node.disconnect/1` | Force-disconnect a node |
| `Node.set_cookie/2` | Set the distribution cookie |
| `Node.get_cookie/0` | Read the current cookie |
| `:erlang.monitor_node/2` | Monitor node up/down events |
| `:global` module | Global name registration across nodes |

**Key insight:** Erlang distribution uses TCP with a **cookie-based auth**
scheme. Nodes with matching cookies can connect; nodes without cannot.
The distribution layer transparently handles message passing, process linking,
and monitoring across nodes — our Elixir `send`, `GenServer.call`,
`Process.monitor`, etc. all work across connected nodes with zero code changes
to the message-passing logic.

The only thing we need to build is:

- A **supervision structure** to track which remote nodes are part of the pack
  cluster and what they can do.
- A **capability advertisement** mechanism so a Pack Leader knows which
  sub-agents it can dispatch where.
- **Fault-tolerance wiring** so disconnections don't orphan work.

---

## 3. High-Level Architecture

```
┌─────────────────────────────┐     ┌─────────────────────────────┐
│      LEADER NODE            │     │      WORKER NODE α          │
│  (operator workstation)     │     │  (dedicated test runner)     │
│                             │     │                              │
│  ┌───────────────────────┐  │     │  ┌───────────────────────┐   │
│  │  PackLeader Agent     │──│─────│──│► PackWorker            │   │
│  │  (LLM-backed)         │  │     │  │  GenServer            │   │
│  └───────┬───────────────┘  │     │  └───────────┬───────────┘   │
│          │                  │     │              │               │
│          ▼                  │     │              ▼               │
│  ┌──────────────────┐       │     │  ┌────────────────────┐      │
│  │ PackDistSupervisor│      │     │  │  PackSubAgentPool   │      │
│  │ (per-node)       │       │     │  │  (Terrier, Watchdog,│      │
│  └──────────────────┘       │     │  │   Shepherd, etc.)   │      │
│                             │     │  └────────────────────┘      │
│  ┌──────────────────┐       │     │                              │
│  │ NodeMonitor       │       │     │   ┌────────────────────┐     │
│  │ (tracks cluster)  │       │     │   │ Local State Store │     │
│  └──────────────────┘       │     │   │ (SQLite shard)     │     │
│                             │     │   └────────────────────┘     │
│  ┌──────────────────┐       │     │                              │
│  │ Local Pack Pool   │       │     │                              │
│  │ (existing)        │       │     │                              │
│  └──────────────────┘       │     │                              │
└─────────────────────────────┘     └─────────────────────────────┘
```

**Connections:**

- Nodes connect via **Erlang distribution** (TCP, cookie-authenticated).
- Each node runs a **`PackWorker` GenServer** that advertises its capabilities.
- The **PackDistSupervisor** on the leader manages one child per remote node,
  monitoring the remote node's liveness via `Node.monitor/2`.
- The Pack Leader sees remote workers as an **extended pool** — it dispatches
  sub-agents to workers based on capability matching (e.g., "I need a Linux
  machine for this build") or round-robin load balancing.

---

## 4. Node Roles

### 4.1 Leader Node

The node where the user interacts with Code Puppy. Runs:

- The full `CodePuppyControl.Application` supervision tree (existing)
- The Pack Leader agent (existing)
- `CodePuppyControl.Pack.NodeMonitor` — tracks cluster membership
- `CodePuppyControl.Pack.DistributedSupervisor` — manages per-remote-node
  child specs (new)
- Local sub-agent pool for fallback (existing)

**Exactly one leader per cluster.** (In future phases, leader failover could
use `:global` registration + distributed ETS, but that's post-v1.)

### 4.2 Worker Node

A headless Erlang node that runs a subset of `CodePuppyControl`. It does NOT
run the full Phoenix Endpoint, the CLI, the TUI, the TUI, or the Pack Leader
agent. It runs:

- `CodePuppyControl.Pack.Worker` GenServer — the entry point for dispatching
  sub-agents from the leader
- Sub-agent implementations (retriever, shepherd, terrier, watchdog) — or a
  subset thereof, based on the worker's advertised capabilities
- Local concurrency limiter (`CodePuppyControl.Plugins.PackParallelism`)
- Optional: local SQLite for scratch state (ephemeral, not the main session DB)

Workers are discovered by the leader via configuration, not by automatic
node discovery (that would be a security risk). The operator lists worker nodes
in `~/.code_puppy/puppy.cfg` under a `[packs.distributed]` section.

### 4.3 Future: Mixed / Peer Nodes

In a more advanced topology, a node could be both a leader (for packs it
initiates) and a worker (for packs initiated by others). This is explicitly
post-v1 — start with strict leader/worker roles.

---

## 5. Supervision Tree Changes

### 5.1 Leader-side additions

```
CodePuppyControl.Supervisor (root)
├── ... (existing children — see application.ex) ...
│
├── CodePuppyControl.Pack.NodeMonitor
│   # One-for-one Supervisor
│   # Starts: monitors remote nodes via Node.monitor/2
│   # Children: {CodePuppyControl.Pack.RemoteNodeTracker, node_name}
│
├── CodePuppyControl.Pack.DistributedSupervisor
│   # DynamicSupervisor — starts one child per configured remote node
│   # Child type: :worker (remote node proxy)
│   # Each child is a CodePuppyControl.Pack.RemoteNodeSupervisor
│
└── CodePuppyControl.Pack.NamingService
    # ETS-backed table mapping {capability, node_name} for fast lookup
    # Updated by NodeMonitor when nodes connect/disconnect
```

### 5.2 Worker-side additions

```
CodePuppyControl.Worker.Supervisor (root — a separate Application)
├── CodePuppyControl.Pack.Worker
│   # GenServer that registers with leader, handles dispatch requests
│   # State: leader_node, capabilities, active_runs
│
├── CodePuppyControl.Plugins.PackParallelism.Supervisor
│   # Local concurrency limiter (same as leader-side, but for worker slot mgmt)
│
└── CodePuppyControl.Pack.SubAgentPool
    # DynamicSupervisor — spawns sub-agent processes on demand
    # Each process is a lightweight GenServer wrapping an LLM-backed agent run
```

### 5.3 `RemoteNodeSupervisor` child spec

```elixir
%{
  id: {:remote_node, node_name},
  start: {CodePuppyControl.Pack.RemoteNodeSupervisor, :start_link, [node_name]},
  type: :supervisor,
  restart: :transient  # Don't restart on disconnect — operator re-adds
}
```

`RemoteNodeSupervisor` is a `Supervisor` with `:one_for_one` strategy.
Its single child is a `RemoteNodeProxy` GenServer that:

- Holds the remote node's atom as state
- Monitors node status via `Node.monitor/2`
- Provides a `dispatch/3` function that sends `GenServer.call` to the
  remote worker
- On `{:nodedown, node}`, emits telemetry, logs, and sets state to
  `:disconnected` (does **not** crash — transient restart handles cleanup)

---

## 6. Message Protocol

### 6.1 Design Decision: GenServer calls over Erlang distribution, NOT PubSub

**No new message broker.** The existing `Phoenix.PubSub` is local-only
(per-VM) — it does not support distribution across nodes without the
`Phoenix.PubSub.PG2` or `Phoenix.PubSub.Redis` adapters, and adding Redis
would violate the "no external dependencies" constraint.

Instead, we use **direct GenServer calls over Erlang distribution**:

| Direction | Pattern | Purpose |
|-----------|---------|---------|
| Leader → Worker | `GenServer.call({:worker_name, remote_node}, {:dispatch, sub_agent, params})` | Start a sub-agent on the worker |
| Leader → Worker | `GenServer.call({:worker_name, remote_node}, {:status, run_id})` | Check on a running sub-agent |
| Worker → Leader | `GenServer.cast({:leader, leader_node}, {:result, run_id, result})` | Return sub-agent result |
| Worker → Leader | `GenServer.cast({:leader, leader_node}, {:progress, run_id, msg})` | Streaming progress updates |
| Leader → Worker | `GenServer.call({:worker_name, remote_node}, {:cancel, run_id})` | Cancel a running sub-agent |
| Leader → All | `GenServer.cast({:worker_name, remote_node}, :ping)` | Health check (used in NodeMonitor) |

### 6.2 Message Shapes

```elixir
# Dispatch a sub-agent to a remote worker
{:dispatch, %{
  run_id: String.t(),           # Unique run identifier
  sub_agent: :terrier,          # :retriever | :shepherd | :terrier | :watchdog
  params: %{                    # Agent-specific parameters
    worktree_path: String.t(),
    branch: String.t(),
    task_description: String.t(),
    model_preference: String.t() | nil  # nil = worker's default
  },
  leader_node: node(),          # Where to send results
  leader_pid: pid()             # Where to reply
}}

# Result from a worker to the leader
{:result, run_id, %{
  status: :success | :failure | :cancelled,
  output: String.t(),           # Textual result summary
  artifacts: [%{path: String.t(), type: String.t()}],
  duration_ms: integer(),
  error: String.t() | nil
}}

# Progress update from worker
{:progress, run_id, %{
  type: :phase | :tool_call | :milestone | :error,
  message: String.t(),
  timestamp: DateTime.t()
}}

# Capability advertisement (sent on connect + on change)
{:capabilities, %{
  node_name: node(),
  sub_agents: [:terrier, :watchdog],     # Which sub-agents this node can run
  host_os: "linux" | "macos" | "windows",
  available_models: [String.t()],        # Which LLM models are configured
  max_concurrent_runs: integer(),        # Slot limit (honors PackParallelism)
  features: %{                            # Feature flags
    file_ops: true,
    shell_access: true,
    git_access: true
  }
}}
```

### 6.3 Why not PubSub for node messaging?

| Concern | PubSub | GenServer.call |
|---------|--------|----------------|
| Distribution adapter | Needs PG2/Redis — external dep or complex setup | Built-in, zero config |
| Request-reply pattern | Requires building correlation layer | Built-in via call/cast |
| Timeouts | Must implement manually | Built-in GenServer timeout |
| Backpressure | None — broadcast is fire-and-forget | Caller blocks on overload |
| Monitoring | None — no process linking | Link + monitor built-in |
| Ordering | Best-effort within topic | FIFO per process mailbox |

**Verdict:** PubSub is wrong for leader-worker dispatch. PubSub stays for
session events (local broadcast to LiveView, TUI, etc.). The inter-node
dispatch uses direct GenServer messages.

---

## 7. Configuration and Bootstrapping

### 7.1 `puppy.cfg` additions

```ini
[packs.distributed]
# Leader identity — must match vm.args -name or -sname
; node_name = pup_leader@192.168.1.100

# Erlang distribution cookie (REQUIRED for cluster auth)
; cookie = your_secret_cookie

# Remote worker nodes
; workers = pup_builder@build-01.local, pup_tester@test-01.local

# Connection timeout (ms)
; connect_timeout = 5000

# Health check interval (ms)
; heartbeat_interval = 15000

# Disconnect grace period (ms) before marking tasks as failed
; disconnect_timeout = 30000

# Per-worker capability overrides (optional — auto-detected)
; [packs.distributed.worker.pup_builder@build-01.local]
; host_os = linux
; max_concurrent_runs = 4
```

### 7.2 Boot sequence (Leader)

1. Read `puppy.cfg` `[packs.distributed]` section.
2. If `cookie` is set, call `Node.set_cookie(:cookie)` before connecting.
3. If `node_name` is set, start node with `Node.start/1` if not already named.
4. For each worker in `workers`:
   a. Attempt `Node.connect(String.to_atom(worker))`.
   b. On success, send `{:capabilities, ...}` probe to the worker.
   c. Start a `RemoteNodeSupervisor` under `DistributedSupervisor`.
   d. Register the worker's capabilities in `NamingService`.
   e. On failure, log and retry on the next heartbeat interval.
5. Start `NodeMonitor` heartbeat loop.

### 7.3 Boot sequence (Worker)

1. Start as a named Erlang node (`--sname pup_worker_01` or `--name`).
2. Start minimal supervision tree (no Phoenix Endpoint, no CLI, no TUI).
3. Start `PackWorker` GenServer with local capabilities.
4. Wait for leader connection (passive — no outbound connections).
5. On leader connect, advertise capabilities via `{:capabilities, ...}` cast.

---

## 8. Fault Tolerance

### 8.1 Remote Node Disconnection

When a remote node disconnects, the following happens:

1. `NodeMonitor` receives `{:nodedown, node}` from its `Node.monitor/2`
   subscription.
2. All active dispatches to that node are **not** immediately failed —
   they enter a `:disconnected` grace period (`disconnect_timeout`).
3. `NodeMonitor` attempts reconnection on each heartbeat interval.
4. If the node reconnects within the grace period:
   - Active runs are checked via `{:status, run_id}` probe.
   - If the run survived the partition (worker process still alive), it
     continues normally.
   - If the run was lost, it's marked as `{:error, :disconnected}`.
5. If the grace period expires:
   - All active runs on that node are marked as `{:error, :disconnected}`.
   - The `RemoteNodeSupervisor` shuts down (transient restart).
   - The node is removed from the `NamingService`.
   - The operator is notified via telemetry + log.

### 8.2 Worker Process Crash

If a worker's sub-agent process crashes:

- The `SubAgentPool` DynamicSupervisor restarts it (if configured).
- The crash is reported to the leader via `{:result, run_id, %{status: :failure, error: ...}}`.
- The leader decides whether to retry (possibly on a different worker node)
  or fail the pack.

### 8.3 Leader Node Crash

Leader crash is **out of scope** for the initial implementation. In a future
phase, `:global` name registration + distributed ETS (`:mnesia` or a custom
replication layer) would allow a standby leader to take over. For v1:

- If the leader crashes, all worker runs are orphaned.
- Workers detect leader node-down via `Node.monitor/2` and mark their runs as
  `:orphaned`.
- Operator intervention is required to recover.

This is consistent with the existing single-node behavior — if the
application crashes, in-flight work is lost.

---

## 9. Security

### 9.1 Cookie Authentication

Erlang distribution uses a **cookie** (a string) for authentication. Nodes
with matching cookies can connect; nodes without cannot. The cookie is:

- Set via `Node.set_cookie(:cookie_atom, "your_secret")`.
- Read from `puppy.cfg` `[packs.distributed] cookie` field.
- OR set via the `RELEASE_COOKIE` environment variable (Burrito convention).
- OR set in `vm.args` via `-setcookie your_secret`.

**Security notes:**

- The cookie is stored in `puppy.cfg` with **0600 permissions** on creation.
- Workers should NOT expose the cookie to sub-agents via environment vars.
- The cookie authenticates the *node*, not the *user* — all processes on a
  connected node are trusted.
- **No encryption by default.** Erlang distribution can be configured with
  TLS (`-proto_dist inet_tls`), but that's a deployment concern, not a
  library concern. Document it as a hardening option.

### 9.2 Node Naming

Node names follow Erlang conventions:

| Type | Format | Example |
|------|--------|---------|
| Short name (same host) | `name@hostname` | `pup_builder@build-01` |
| Long name (different host) | `name@hostname.domain` | `pup_tester@192.168.1.50` |

Workers should use **short names** for same-host clusters and **long names**
for cross-host clusters. The `node_name` config field accepts both.

### 9.3 Firewalling

Erlang distribution's epmd (Erlang Port Mapper Daemon) listens on port 4369.
Individual nodes allocate dynamic ports for distribution. To firewall:

- Allow port 4369 (TCP) for epmd.
- Pin distribution ports via kernel config:
  ```erlang
  % In vm.args or sys.config
  -kernel inet_dist_listen_min 9100
  -kernel inet_dist_listen_max 9155
  ```
- Only allow connections from known leader/worker IPs.

### 9.4 Sub-Agent Permission Boundaries

Even though the node is trusted, sub-agents running on a remote worker should
**not** have access to the leader's credentials, session DB, or config unless
explicitly scoped. This is enforced by:

- **Different cookie** per cluster deployment (not per-session).
- **Minimal API surface** — the leader dispatches via `GenServer.call` with
  explicit parameters, not by exposing the full tool/agent API.
- **Worker-only ETS** — worker nodes have their own `:pack_parallelism_limits`
  ETS table, separate from the leader's.
- **No automatic config sync** — each worker has its own `puppy.cfg`. The
  leader does not push config to workers.

---

## 10. Capability Advertisement

Workers advertise what they can do. This allows the Pack Leader to make
informed dispatch decisions:

```elixir
# Published by PackWorker on connect and periodically
%{
  node_name: :"pup_builder@build-01",
  sub_agents: [:terrier, :watchdog],  # Doesn't run shepherds
  host_os: "linux",
  available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"],
  max_concurrent_runs: 4,
  features: %{
    file_ops: true,
    shell_access: true,
    git_access: true,
    docker_access: false
  }
}
```

The `NamingService` on the leader maintains an ETS table:

```elixir
# Key: {sub_agent_type, capability_key}
# Value: list of qualifying nodes
:ets.new(:pack_worker_capabilities, [:set, :public, :named_table])

# Example rows:
# {{:terrier, :linux}, [:"pup_builder@build-01", :"pup_worker@dev-box"]}
# {{:watchdog, :linux}, [:"pup_builder@build-01"]}
# {{:shepherd, :macos}, [:"pup_local@Adams-MacBook-Pro"]}
```

The Pack Leader can query: "Give me all nodes that can run a watchdog on
Linux" and then pick one round-robin, by load, or by explicit hint.

---

## 11. Synchronous vs Asynchronous Dispatch

### 11.1 The Trade-off

| Aspect | Synchronous (call) | Asynchronous (cast + result callback) |
|--------|-------------------|---------------------------------------|
| Simplicity | Single call/return | Two-phase: dispatch → wait for result |
| Backpressure | Caller blocks | Queue-based, requires slot mgmt |
| Timeout handling | Built-in GenServer timeout | Custom timeout timer needed |
| Streaming progress | Impossible (call blocks) | Possible via intermediate casts |
| Network latency | Adds to pack wall-clock | Hides behind parallelism |

### 11.2 Recommendation: Async with Result Callback

For the initial implementation, use **asynchronous dispatch** with a
result callback. Rationale:

1. **Network latency is unpredictable.** A sync call across a WAN could
   time out the GenServer call for no good reason.
2. **Progress reporting matters.** The user wants to see "Worker building..."
   not a hanging call.
3. **Workers have their own slot managers.** A sync call would block the
   leader process while the worker queues the work internally.
4. **Cancellation support.** An async dispatch can be cancelled by sending
   a separate message. A sync call can only be `Process.exit/2`'d.

The flow:

```
Leader                              Worker
  │                                    │
  ├─ {dispatch, run_id, params} ──────►│  (cast)
  │                                    ├─ Spawn sub-agent process
  │◄── {progress, run_id, "started"} ──│  (cast back)
  │◄── {progress, run_id, "running"} ──│  (cast back)
  │◄── {result, run_id, output} ───────│  (cast back — final)
  │  (Leader processes result)          │
```

The leader maintains a `%{run_id => %{pid: mon_ref, callback: fun, started_at: time}}`
map in the `RemoteNodeProxy` GenServer state. When a result arrives, the
callback is invoked.

### 11.3 Sync Option for Local Nodes

When the worker is on the **same host** (loopback, low latency < 1ms), a
synchronous `GenServer.call` with reasonable timeout (e.g., 30s per dispatch)
is acceptable and simpler. The `RemoteNodeProxy` can detect same-host workers
by comparing the remote hostname to the local hostname.

### 11.4 Configuration Knob

```elixir
config :code_puppy_control, :distributed_packs,
  dispatch_style: :async,         # :async (default) | :sync_local | :sync_all
  sync_timeout: 30_000            # Only used for sync dispatch
```

---

## 12. Capabilities vs. Functionality: What Workers Run

### 12.1 Worker-side supervision tree

Workers run a **lightweight** supervision tree:

```
CodePuppyControl.Worker.Supervisor
├── CodePuppyControl.Repo          # SQLite for local scratch storage
├── CodePuppyControl.Pack.Worker   # Main dispatch GenServer
├── CodePuppyControl.Pack.SubAgentPool  # DynamicSupervisor for sub-agents
├── CodePuppyControl.Plugins.PackParallelism.Supervisor
├── CodePuppyControl.ModelFactory.ProviderRegistry
├── CodePuppyControl.ModelRegistry
├── CodePuppyControl.HttpClient    # Finch for LLM calls
├── CodePuppyControl.Tool.Registry
└── CodePuppyControl.Tool.Runner   # Tool execution (shell, file ops)
```

**NOT started on workers:**

- `CodePuppyControlWeb.Endpoint` (Phoenix HTTP)
- `CodePuppyControl.CLI.*` (CLI, TUI, REPL)
- `CodePuppyControl.SessionStorage.*` (session state is leader-only)
- `CodePuppyControl.Plugins.*` (plugins are leader-only)
- `CodePuppyControl.Config.Writer` (workers don't write config)
- `CodePuppyControl.PolicyEngine` (policy is leader-enforced)
- `CodePuppyControl.Callbacks.Registry` (callbacks are leader-only)
- `CodePuppyControl.RequestTracker` (request tracking is leader-only)

### 12.2 Sub-Agent Execution Model

When a worker receives a `{:dispatch, run_id, params}` cast:

1. `PackWorker` validates the params against its capabilities.
2. If params.requested_model is not available on this worker, reject.
3. Acquire a pack parallelism slot (local `PackParallelism.acquire`).
4. Start a sub-agent process under `SubAgentPool` DynamicSupervisor.
5. The sub-agent process:
   a. Initializes with the task description, tools, and model.
   b. Executes the LLM-backed agent loop (same as local agent execution).
   c. Sends progress casts back to leader.
   d. On completion, sends `{:result, run_id, result}` to leader.
   e. Releases the pack parallelism slot.
6. `PackWorker` casts the `:result` to the leader's proxy pid.

---

## 13. Migration Path: Single-Node → Multi-Node

### 13.1 Phase 0: No-op (this branch)

- Design document written.
- Prototype supervision module created.
- No runtime impact — all existing code works unchanged.
- `CodePuppyControl.Pack.DistributedSupervisor` and `NodeMonitor` are
  **not** added to the supervision tree yet.

### 13.2 Phase 1: DistributedSupervisor skeleton

- Add the supervision modules to the tree, **disabled by default**.
- Configuration key: `packs.distributed.enabled = false`.
- NodeMonitor starts but does nothing when disabled.
- All existing tests pass, no behavior change.

### 13.3 Phase 2: Worker-mode Application

- Create `CodePuppyControl.Worker.Application` — a separate OTP Application
  for worker nodes.
- Worker starts with `--sname pup_worker_01` and joins the leader.
- Add `/pack worker start` and `/pack leader connect` slash commands.
- Integration test: one Leader node + one Worker node on localhost.

### 13.4 Phase 3: Capability-aware dispatch

- Pack Leader can query available workers.
- On `cp_invoke_agent("terrier", "create worktree")`, the leader can
  optionally specify `node: :"pup_builder@build-01"`.
- Default behavior: dispatch locally (same as today).

### 13.5 Phase 4: Automatic load balancing

- Pack Leader auto-selects the least-loaded node for dispatch.
- Round-robin across workers with matching capabilities.
- Graceful degradation: if no remote workers match, fall back to local.

### 13.6 Rollback

**At any phase:** set `packs.distributed.enabled = false` and the cluster
code is a no-op. The existing local pack parallelism behavior is preserved.

---

## 14. Telemetry and Observability

```elixir
# Node lifecycle
[:code_puppy, :distributed_pack, :node, :connected]
  → %{node: node(), capabilities: map()}

[:code_puppy, :distributed_pack, :node, :disconnected]
  → %{node: node(), active_runs: [run_id], reason: term()}

[:code_puppy, :distributed_pack, :node, :reconnected]
  → %{node: node(), grace_period_ms: integer()}

# Dispatch lifecycle
[:code_puppy, :distributed_pack, :dispatch, :start]
  → %{run_id: String.t(), sub_agent: atom(), target_node: node()}

[:code_puppy, :distributed_pack, :dispatch, :stop]
  → %{run_id: String.t(), status: atom(), duration_ms: integer()}

[:code_puppy, :distributed_pack, :dispatch, :exception]
  → %{run_id: String.t(), error: String.t()}

# Capability events
[:code_puppy, :distributed_pack, :capabilities, :updated]
  → %{node: node(), capabilities: map()}
```

---

## 15. Testing Strategy

### 15.1 Unit Tests (Local-Only)

- `RemoteNodeProxy` with a mock remote worker (start a second Elixir node
  on localhost with `Node.start/1` and `Node.connect/1`).
- `NodeMonitor` with simulated `{:nodedown, ...}` messages from a test pid.
- `NamingService` ETS upsert/lookup/delete under concurrent access.

### 15.2 Integration Tests (Two-Node)

- Start two Elixir nodes in the test: one as leader, one as worker.
- Use different short names (e.g., `leader_test@127.0.0.1`,
  `worker_test@127.0.0.1`).
- Set a shared cookie, connect, dispatch a sub-agent.
- Assert the sub-agent runs on the worker and returns results.
- Kill the worker node, assert leader detects disconnection.
- Restart the worker, assert reconnection.

### 15.3 Property Tests

- `StreamData` for capability advertisement shapes.
- Simulated network delay + disconnection scenarios.

---

## 16. Open Questions and Future Work

### 16.1 Questions for the Operator

1. **TLS for distribution?** Erlang distribution can be secured with TLS
   (`-proto_dist inet_tls`). Should this be a deployment-time concern or
   should we provide a helper? (Proposal: deployment-time only — provide a
   doc section in this document.)

2. **Ephemeral vs. persistent workers?** Should workers persist state to
   SQLite, or is everything ephemeral (capabilities are re-discovered on
   reconnect)? (Proposal: ephemeral for v1, persistent for v2.)

3. **Leader failover?** v1 has no leader failover. Should we design the
   state protocol to allow it in v2? (Proposal: yes — use `:global`
   registered name + asynchronously replicated run state.)

### 16.2 Future Feature Candidates

- **Distributed ETS** via `:mnesia` for cross-node capability tables.
- **Leader election** via `:global` name conflict + tiebreaker.
- **Worker pool auto-scaling** (start/stop workers on demand via SSH/docker).
- **Per-worker credentials isolation** (workers have their own crypto keys).
- **File artifact sync** between worker and leader (rsync/SCP for worktree
  checkout results).
- **Phoenix LiveView dashboard** for cluster status (post v1).

---

## 17. Appendix: Example Config

### Full `puppy.cfg` for a distributed cluster

```ini
[packs.distributed]
enabled = true
node_name = pup_leader@192.168.1.100
cookie = changeme_cookie_value
workers = pup_tester@10.0.0.50, pup_builder@10.0.0.51
connect_timeout = 5000
heartbeat_interval = 15000
disconnect_timeout = 30000
dispatch_style = async

# Override capabilities for specific workers
[packs.distributed.worker.pup_builder@10.0.0.51]
host_os = linux
max_concurrent_runs = 8
sub_agents = terrier, watchdog
features.shell_access = true
features.docker_access = true
features.git_access = true
```

### Worker startup

```bash
# On the worker machine:
pup worker --sname pup_tester@10.0.0.50 --cookie changeme_cookie_value

# Or via config:
#   puppy.cfg on the worker:
#     [worker]
#     node_name = pup_tester@10.0.0.50
#     cookie = changeme_cookie_value
#     leader = pup_leader@192.168.1.100
```

---

## 18. Related Files

| File | Purpose |
|------|---------|
| `lib/code_puppy_control/pack/distributed_supervisor.ex` | Prototype supervision module |
| `lib/code_puppy_control/application.ex` | Root supervision tree (leader) |
| `lib/code_puppy_control/agents/pack_leader.ex` | Pack Leader agent |
| `lib/code_puppy_control/plugins/pack_parallelism/` | Existing concurrency limiter |
| `lib/code_puppy_control/event_bus.ex` | Local PubSub (NOT used for inter-node) |
| `ROADMAP.md` | Phase tracking → Distributed packs → This issue |
