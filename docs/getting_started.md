# Getting Started

> 🐶 **Default runtime: Elixir CLI** → [ELIXIR_CLI_QUICKSTART.md](ELIXIR_CLI_QUICKSTART.md)
>
> Python is optional and required only for **explicit bridge-worker** or **legacy Python CLI** flows.

## Quickstart

### Elixir (default — recommended)

```bash
cd elixir/code_puppy_control
mix deps.get
mix escript.build
./pup --help
```

See the full [Elixir CLI daily-driver guide](ELIXIR_CLI_QUICKSTART.md) for setup, credentials, smoke tests, and troubleshooting.

### Python (optional — bridge/legacy)

If you need the Python CLI (e.g., for bridge-worker mode or legacy workflows):

```bash
pip install -e .
code-puppy --bridge-mode
```

> **Note:** New development targets the Elixir runtime. The Python CLI is maintained for backward compatibility and bridge orchestration. `code-puppy` is the canonical Python/PyPI command; Python `pup` is a legacy alias. Run `PUP_RUNTIME=python ./pup` from the Elixir CLI to delegate to the Python bridge (see [ELIXIR_CLI_QUICKSTART.md#python-bridge-worker-mode-optional](ELIXIR_CLI_QUICKSTART.md#python-bridge-worker-mode-optional)).

## What to read next

| Topic | Document |
|-------|----------|
| Elixir CLI daily-driver guide (primary) | [ELIXIR_CLI_QUICKSTART.md](ELIXIR_CLI_QUICKSTART.md) |
| Architecture overview | [architecture.md](architecture.md) |
| Dual-home config isolation (ADR-003) | [adr/ADR-003-dual-home-config-isolation.md](adr/ADR-003-dual-home-config-isolation.md) |
| Plugin system | [plugins.md](plugins.md) |
| Hook system | [HOOKS.md](HOOKS.md) |
| Config specification | [config_spec.md](config_spec.md) |
| Elixir README | [../elixir/code_puppy_control/README.md](../elixir/code_puppy_control/README.md) |
