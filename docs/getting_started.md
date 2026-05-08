# Getting Started

> 🐶 **Default runtime: Burrito native binary** → download from [GitHub Releases](https://github.com/mpfaffenberger/code_puppy/releases)
>
> The Burrito binary is the recommended daily-driver — fully self-contained, no Erlang/Elixir/Python required.
> The escript is available for local dev/smoke testing but is a degraded runtime (no Repo/Oban/Endpoint).
> Python is optional and required only for **explicit bridge-worker** or **legacy Python CLI** flows.

## Quickstart

### Burrito Native Binary (recommended)

```bash
# Download from GitHub Releases for your platform
# Linux (x86_64):
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_linux_x86_64 -o pup
chmod +x pup && ./pup --help
```

See [GitHub Releases](https://github.com/mpfaffenberger/code_puppy/releases) for macOS and other platforms.

`PUP_RUNTIME=elixir` (or unset) is the default — no Python required.

### Escript (dev / smoke testing)

```bash
mix deps.get
mix escript.build
./pup --help
```

> **Note:** The escript is a degraded runtime — it lacks Repo/Oban/Phoenix Endpoint (no database, scheduler, or admin UI). Prefer the Burrito binary for real work.

See the full [Elixir CLI daily-driver guide](ELIXIR_CLI_QUICKSTART.md) for setup, credentials, smoke tests, and troubleshooting.

### Python (optional — bridge/legacy)

If you need the Python CLI (e.g., for bridge-worker mode or legacy workflows):

```bash
pip install -e .
code-puppy --bridge-mode
```

> **Note:** New development targets the Elixir runtime. The Python CLI is maintained for backward compatibility and bridge orchestration. `code-puppy` is the canonical Python/PyPI command; Python `pup` is a legacy alias being deprecated ([deprecation plan](release/python-pup-alias-deprecation-plan.md)). Run `PUP_RUNTIME=python ./pup` from the Elixir CLI to delegate to the Python bridge (see [ELIXIR_CLI_QUICKSTART.md#python-bridge-worker-mode-optional](ELIXIR_CLI_QUICKSTART.md#python-bridge-worker-mode-optional)).

### Version Streams

| Stream | Version | Source | Recommended for |
|--------|---------|--------|------------------|
| Elixir-native | `0.1.x` | `mix.exs` | Daily driver (Burrito binary or escript) |
| Python/PyPI compat | `0.0.x` | `pyproject.toml` | Bridge mode / legacy Python CLI only |

## What to read next

| Topic | Document |
|-------|----------|
| Elixir CLI daily-driver guide (primary) | [ELIXIR_CLI_QUICKSTART.md](ELIXIR_CLI_QUICKSTART.md) |
| Runtime selection & acceleration | [acceleration.md](acceleration.md) |
| Architecture overview | [architecture.md](architecture.md) |
| Dual-home config isolation (ADR-003) | [adr/ADR-003-dual-home-config-isolation.md](adr/ADR-003-dual-home-config-isolation.md) |
| Plugin system | [plugins.md](plugins.md) |
| Hook system | [HOOKS.md](HOOKS.md) |
| Config specification | [config_spec.md](config_spec.md) |
| Python `pup` alias deprecation | [release/python-pup-alias-deprecation-plan.md](release/python-pup-alias-deprecation-plan.md) |
| Project README / full overview | [../README.md](../README.md) |
