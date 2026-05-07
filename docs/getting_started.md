# Getting Started

> 🐶 **Default runtime: Burrito native binary** → download from [GitHub Releases](https://github.com/mpfaffenberger/code_puppy/releases)
>
> The Burrito binary is the recommended daily-driver — fully self-contained, no Erlang/Elixir/Python required.
> The escript is available for local dev/smoke testing but is a degraded runtime (no Repo/Oban/Endpoint).

## Quickstart

### Burrito Native Binary (recommended)

```bash
# Download from GitHub Releases for your platform
# Linux (x86_64):
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_linux_x86_64 -o pup
chmod +x pup && ./pup --help
```

See [GitHub Releases](https://github.com/mpfaffenberger/code_puppy/releases) for macOS and other platforms.

### Escript (dev / smoke testing)

```bash
cd elixir/code_puppy_control
mix deps.get
mix escript.build
./pup --help
```

> **Note:** The escript is a degraded runtime — it lacks Repo/Oban/Phoenix Endpoint (no database, scheduler, or admin UI). Prefer the Burrito binary for real work.

See the full [Elixir CLI daily-driver guide](ELIXIR_CLI_QUICKSTART.md) for setup, credentials, smoke tests, and troubleshooting.

## Version

The current version stream is `0.1.x` from `mix.exs`. The Burrito binary is the full-featured daily-driver; the escript is dev/smoke only (no Repo/Oban/Endpoint).

## What to read next

| Topic | Document |
|-------|----------|
| Elixir CLI daily-driver guide (primary) | [ELIXIR_CLI_QUICKSTART.md](ELIXIR_CLI_QUICKSTART.md) |
| Architecture overview | [architecture.md](architecture.md) |
| Plugin system | [plugins.md](plugins.md) |
| Hook system | [HOOKS.md](HOOKS.md) |
| Config specification | [config_spec.md](config_spec.md) |
| Elixir README | [../elixir/code_puppy_control/README.md](../elixir/code_puppy_control/README.md) |
