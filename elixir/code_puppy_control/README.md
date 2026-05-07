# CodePuppyControl

Elixir-native Phoenix control plane for the code_puppy project.

## Architecture

This application is an Elixir-native runtime. There is no
`pup-ex` executable: `pup_ex` is the Mix task namespace, while the native CLI is
`./pup` (escript) or a `code_puppy_control_*` Burrito binary.

- **Phoenix API** - HTTP API for run management and tool execution
- **Registry** - Process registry for run and worker tracking
- **PubSub** - Event distribution across processes
- **Oban** - Job scheduling for background tasks
- **Run Executor** - Elixir-native `Tool.Runner`

## Directory Structure

```
lib/code_puppy_control/
├── application.ex # OTP supervision tree
├── protocol.ex # JSON-RPC encoding/decoding
├── request_tracker.ex # Prompt correlation
├── run/
│   ├── executor.ex # Executor facade (native Elixir)
│   ├── executor/
│   │   ├── behaviour.ex # Executor behaviour
│   │   ├── elixir.ex # Elixir-native executor
│   │   └── supervisor.ex # DynamicSupervisor for executors
│   ├── manager.ex # Run lifecycle management
│   ├── registry.ex # Run registry
│   ├── state.ex # Run state GenServer
│   └── supervisor.ex # DynamicSupervisor for runs
├── tool/
│   ├── runner.ex # Elixir-native tool runner (default)
│   ├── registry.ex # Tool discovery and registration
│   ├── schema.ex # Tool parameter schemas
│   └── behaviour.ex # Tool behaviour definition
└── web/
    ├── endpoint.ex # Phoenix endpoint
    ├── router.ex # API routes
    └── controllers/
        ├── run_controller.ex # Run management
        └── health_controller.ex # Health checks
```

## Quick Start

```bash
# Install dependencies
mix deps.get

# Run no-network dogfood smoke
mix pup_ex.smoke

# Setup database (SQLite)
mix ecto.setup

# Run tests
mix test

# Start the server
mix phx.server
```

For the full Elixir CLI daily-driver guide (setup, credentials, escript build, usage, troubleshooting), see [docs/ELIXIR_CLI_QUICKSTART.md](../../docs/ELIXIR_CLI_QUICKSTART.md).

## Running Tests

The test suite uses **SQLite** (not PostgreSQL) because the repo, migrations,
and Oban setup are all SQLite-specific. No external database is needed.

### Concurrency profiles

On laptops (especially fanless ones like the M4 Air), running all scheduler
cores at once causes thermal throttling. Use `PUP_TEST_PROFILE` to control
parallelism (approximate counts on a 10-scheduler machine per `mix test` process):

| Profile | Flag | Approx. cases on 10-scheduler machine |
|---------|------|-----------------------------------------|
| balanced | *(default)* | ~6 |
| gentle | `PUP_TEST_PROFILE=gentle` | ~3 |
| burst | `PUP_TEST_PROFILE=burst` | ~9-10 |

```bash
# Default (balanced)
mix test

# Keep it cool
PUP_TEST_PROFILE=gentle mix test

# Fast / CI-style
PUP_TEST_PROFILE=burst mix test

# Exact override
PUP_TEST_MAX_CASES=2 mix test
```

Explicit CLI flags (`--trace`, `--max-cases`, `--max-cases=N`) always take
precedence over environment variables.

**SQLite test database:**
- The default test DB lives under the system temp directory (`System.tmp_dir/0`).
- It is partition-aware (uses `MIX_TEST_PARTITION` in the path if set).
- It is **not** automatically fresh between runs; data persists across test runs.
- Override with `PUP_TEST_DB` to use a custom path.

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/api/runs` | POST | Create new run |
| `/api/runs/:id` | GET | Get run status |
| `/api/runs/:id` | DELETE | Stop run |
| `/api/runs/:id/execute` | POST | Execute tool |
| `/api/runs/:id/history` | GET | Get history |

## Configuration

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `PUP_SECRET_KEY_BASE` | Phoenix secret key | Production (auto-generated for Burrito) |
| `PUP_DATABASE_PATH` | SQLite database path | Production (auto-defaulted for Burrito) |

> **Legacy env vars** `SECRET_KEY_BASE` and
> `DATABASE_PATH` are still accepted but deprecated. They log a
> warning on use. Prefer the `PUP_`-prefixed names.
>
> `PUPPY_HOME` is also deprecated in favour of `PUP_EX_HOME` — see
> Dual-Home Config Isolation below.

### Dual-Home Config Isolation

Elixir pup-ex uses a **separate home directory** from Python pup to prevent config
corruption during the migration. See [ADR-003](../../docs/adr/ADR-003-dual-home-config-isolation.md)
for full design.

| Runtime | Home directory | Status |
|---------|---------------|--------|
| Elixir pup-ex | `~/.code_puppy_ex/` (or `PUP_EX_HOME`) | ✅ Read + write |
| Python pup | `~/.code_puppy/` (legacy) | 📖 Read-only via explicit import |

**Runtime enforcement:** All filesystem writes go through `CodePuppyControl.Config.Isolation`.
Any attempt to write under `~/.code_puppy/` raises `IsolationViolation` — no exceptions.

#### First-time setup

If you're a user with an existing `~/.code_puppy/` from Python pup:

```bash
# Copy non-sensitive settings over (dry-run by default)
mix pup_ex.import # shows what WOULD be copied
mix pup_ex.import --confirm # actually copies

# Verify isolation health
mix pup_ex.doctor # reports ✅ ISOLATED on healthy setup
```

The importer copies an **allowlist** of non-sensitive files only:
- `extra_models.json`, user additions in `models.json`
- `[ui]` section of `puppy.cfg`
- `agents/` and `skills/` directories

**Never copied:** OAuth tokens, sessions, API keys, `dbos_store.sqlite`, command history.
Re-authenticate with `mix pup_ex.auth.login` (OAuth scaffolding; full flow pending).

#### Relevant environment variables

| Variable | Purpose | Default |
|----------|---------|--------|
| `PUP_EX_HOME` | Override Elixir home directory | `~/.code_puppy_ex/` |
| `PUP_HOME` | **Deprecated** — logs a warning; use `PUP_EX_HOME` | — |
| `PUPPY_HOME` | **Legacy** — logs a warning; use `PUP_EX_HOME` | — |

## Development

### IEx Session

```bash
iex -S mix

# Check active runs
CodePuppyControl.Run.Supervisor.list_runs()

# Start a run (uses Elixir executor)
CodePuppyControl.Run.Supervisor.start_run("test-run-1", %{})
```

### JSON-RPC Protocol

The control plane uses JSON-RPC 2.0 with Content-Length framing
for select communication paths (e.g. MCP protocol):

```
Content-Length: 47\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize"}
```

See `lib/code_puppy_control/protocol.ex` for encoding/decoding functions.

### Running Evals

Eval tests (`:eval` tag) are excluded by default and run only when
`RUN_EVALS=1` is set in the environment. This mirrors the Python
`evals/conftest.py` gate.

```bash
# Default: skip all evals
mix test

# Run only evals
RUN_EVALS=1 mix test --only eval

# Run the harness parity gate (not tagged :eval, always runs)
mix test test/code_puppy_control/evals/logger_test.exs
```

Eval results are logged as JSON to `<repo_root>/evals/logs/<sanitized_name>.json`
using the SAME schema as the Python harness, so cross-runtime parity diffs are a
`jq 'del(.timestamp)' | diff` away.

### Running Isolation Gates

The 5 CI gates from ADR-003 are consolidated in a dedicated test file:

```bash
mix gates.isolation
```

This runs the 8 gate tests (GATE-1 through GATE-5) in under a second. The gates
also run automatically on every PR that touches config, pup_ex tasks, or the
workflow itself (see `.github/workflows/elixir-isolation-gates.yml`).

## Building a Single-Binary Release (Burrito)

For self-contained distribution without requiring Erlang/Elixir on the target
machine, use Burrito via `scripts/build-burrito.sh`. Requires Zig on PATH.

See [docs/burrito-release.md](docs/burrito-release.md) for prerequisites,
platform matrix, and troubleshooting.

## License

Same as the main code_puppy project.
