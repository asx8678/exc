<div align="center">

**🐶✨The sassy AI code agent that makes IDEs look outdated** ✨🐶

[![Version](https://img.shields.io/pypi/v/codepp?style=for-the-badge&logo=python&label=Version&color=purple)](https://pypi.org/project/codepp/)
[![Downloads](https://img.shields.io/badge/Downloads-170k%2B-brightgreen?style=for-the-badge&logo=download)](https://pypi.org/project/codepp/)
[![Python](https://img.shields.io/badge/Python-3.14+-blue?style=for-the-badge&logo=python&logoColor=white)](https://python.org)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

[![100% Open Source](https://img.shields.io/badge/100%25-Open%20Source-blue?style=for-the-badge)](https://github.com/mpfaffenberger/code_puppy)
[![Pydantic AI](https://img.shields.io/badge/Pydantic-AI-success?style=for-the-badge)](https://github.com/pydantic/pydantic-ai)

[![100% privacy](https://img.shields.io/badge/FULL-Privacy%20commitment-blue?style=for-the-badge)](https://github.com/mpfaffenberger/code_puppy/blob/main/README.md#code-puppy-privacy-commitment)

[![GitHub stars](https://img.shields.io/github/stars/mpfaffenberger/code_puppy?style=for-the-badge&logo=github)](https://github.com/mpfaffenberger/code_puppy/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/mpfaffenberger/code_puppy?style=for-the-badge&logo=github)](https://github.com/mpfaffenberger/code_puppy/network)

[![Discord](https://img.shields.io/badge/Discord-Community-purple?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/eAGdE4J7Ca)
[![Docs](https://img.shields.io/badge/Read-The%20Docs-blue?style=for-the-badge&logo=readthedocs)](https://code-puppy.dev)

**[⭐ Star this repo if you hate expensive IDEs! ⭐](#quick-start)**

*"Who needs an IDE when you have 1024 angry puppies?"* - Someone, probably.

</div>

```
    ███████╗ █████╗ ███████╗████████╗    ██████╗ ██╗   ██╗██████╗ ██████╗ ██╗   ██╗
    ██╔════╝██╔══██╗██╔════╝╚══██╔══╝    ██╔══██╗██║   ██║██╔══██╗██╔══██╗╚██╗ ██╔╝
    █████╗  ███████║███████╗   ██║       ██████╔╝██║   ██║██████╔╝██████╔╝ ╚████╔╝ 
    ██╔══╝  ██╔══██║╚════██║   ██║       ██╔═══╝ ██║   ██║██╔═══╝ ██╔═══╝   ╚██╔╝  
    ██║     ██║  ██║███████║   ██║       ██║     ╚██████╔╝██║     ██║        ██║   
    ╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝       ╚═╝      ╚═════╝ ╚═╝     ╚═╝        ╚═╝   
```

**🚀 Elixir-native by default — Python is now an optional compatibility path! 🚀**

---



## Overview

*This project was coded angrily in reaction to Windsurf and Cursor removing access to models and raising prices.*

*You could also run 50 code puppies at once if you were insane enough.*

*Would you rather plow a field with one ox or 1024 puppies?*
    - If you pick the ox, better slam that back button in your browser.


Code Puppy is an AI-powered code generation agent, designed to understand programming tasks, generate high-quality code, and explain its reasoning similar to tools like Windsurf and Cursor.

## Fork Enhancements

This fork adds significant capabilities to the original code_puppy, transforming it from a coding assistant into an enterprise-grade multi-agent development platform.

| Feature | Description | Speedup/Impact |
|---------|-------------|----------------|
| ⚡ Native Runtime | Elixir-native runtime with an optional Python compatibility bridge | 10-50x faster |
| 🐕 Pack Parallelism | 8-agent concurrent execution with intelligent queuing | 8x throughput |
| 📚 Progressive Skills | Metadata-only skill injection until needed | Zero context cost |
| 🔍 Supervisor Review | Quality-gated multi-agent review loops | Higher quality |
| 📝 Session Logger | Structured archives with full audit trail | Debugging/compliance |
| 🔐 OAuth Integration | 2 providers (ChatGPT, Claude) | Better UX |
| 💾 DBOS Durability | Workflow checkpointing and recovery | Crash survival |
| 🔄 Round Robin | Model distribution across multiple keys | Rate limit bypass |
| 🌐 Models.dev | 65+ providers, 1000+ models | One-click setup |

**48 plugins** • **18+ agents** • **150+ merged feature branches**

📋 **Full changelog**: See [FORK_CHANGELOG.md](FORK_CHANGELOG.md) for complete documentation of all features, modifications, and performance benchmarks.

## Quick start

**Burrito native binary** is the recommended daily-driver — a self-contained executable with no Erlang/Elixir/Python install required:

```bash
# Download the latest Burrito release for your platform from GitHub Releases
# Linux (x86_64):
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_linux_x86_64 -o pup
chmod +x pup && ./pup -i

# macOS (Apple Silicon):
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_macos_arm64 -o pup
chmod +x pup && ./pup -i
```

> **Escript (dev/smoke only):** `mix escript.build` produces a `./pup` escript for local development and smoke testing. The escript is a **degraded** runtime — it lacks Repo/Oban/Phoenix Endpoint (no database, no scheduler, no admin UI). Prefer the Burrito binary for real work.

Legacy/PyPI compatibility path (Python package — bridge mode or legacy Python CLI only):

```bash
uvx --from codepp code-puppy -i
```

> **Version streams & CLI name collision:**
> - **Elixir-native (0.1.x):** Burrito `code_puppy_control_*` binaries and `mix escript.build` → `./pup` both report the `0.1.x` stream from `mix.exs`. The Burrito binary is the full-featured daily-driver; the escript is dev/smoke only (no Repo/Oban/Endpoint).
> - **Python/PyPI compatibility (0.0.x):** `codepp` installs canonical `code-puppy` plus a legacy `pup` alias reporting the `0.0.x` stream from `pyproject.toml`. The Python `pup` alias is being deprecated — see [the deprecation plan](docs/release/python-pup-alias-deprecation-plan.md).
> - If both are on `PATH`, shell order decides. For Python flows, use `uvx --from codepp code-puppy` or a known Python venv's `code-puppy`. For Elixir flows, use the Burrito binary or `./pup` (escript). No `pup-ex` executable exists; `pup_ex` names Mix tasks only.
> - **`PUP_RUNTIME=elixir`** is the canonical no-Python runtime selector. `PUP_RUNTIME=python` or `--bridge-mode` activates the Python compatibility bridge.

## Installation

### Burrito Native Binary (Recommended)

The Burrito binary is a fully self-contained executable — **no Erlang, Elixir, or Python install required**. It includes the complete OTP release with Repo/Oban/Phoenix Endpoint (database, scheduler, admin UI), making it the recommended daily-driver path.

```bash
# Download the latest release for your platform from GitHub Releases:
# https://github.com/mpfaffenberger/code_puppy/releases

# Linux (x86_64)
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_linux_x86_64 -o pup
chmod +x pup
./pup -i

# macOS (Apple Silicon)
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_macos_arm64 -o pup
chmod +x pup
./pup -i

# macOS (Intel)
curl -L https://github.com/mpfaffenberger/code_puppy/releases/latest/download/code_puppy_control_macos_x86_64 -o pup
chmod +x pup
./pup -i
```

> **Runtime selector:** `PUP_RUNTIME=elixir` (or unset/`auto`) is the default. No Python is required or invoked.
> Set `PUP_RUNTIME=python` or pass `--bridge-mode` only when you need the Python compatibility bridge.

### Escript Build (Dev / Smoke Testing)

The escript is useful for local development and smoke testing, but is a **degraded runtime** — it lacks Repo/Oban/Phoenix Endpoint (no database, scheduler, or admin UI). For real work, prefer the Burrito binary above.

```bash
cd elixir/code_puppy_control
mix deps.get
MIX_ENV=prod mix escript.build
./pup --help
```

### UV / PyPI (Compatibility / Legacy Python Bridge)

The PyPI package is kept for compatibility and for users who specifically need the Python CLI or bridge. It can still connect to the Elixir runtime when available, but the Burrito/Elixir-native path is the default. In the Python/PyPI package, the canonical command is `code-puppy`; the Python `pup` command is a legacy alias being deprecated (see the [deprecation plan](docs/release/python-pup-alias-deprecation-plan.md) for details and timeline).

#### macOS / Linux

```bash
# Install UV if you don't have it
curl -LsSf https://astral.sh/uv/install.sh | sh

# This fork is published to PyPI as `codepp`. The installed script is still
# called `code-puppy`, so `uvx --from codepp code-puppy` runs this build.
uvx --from codepp code-puppy
```

#### Windows

For the legacy Python/PyPI path on Windows, install code-puppy as a global tool for the best experience with keyboard shortcuts (Ctrl+C/Ctrl+X cancellation):

```powershell
# Install UV if you don't have it (run in PowerShell as Admin)
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

# This fork is published to PyPI as `codepp`; the installed command is code-puppy.
uvx --from codepp code-puppy
```

### Local Development

For local development with graceful multi-service shutdown:

```bash
./scripts/run_dev.sh           # start dev services (placeholder - see issue code_puppy-ac5)
./scripts/run_dev.sh --help    # see options
```

## Changelog (By Kittylog!)

[📋 View the full changelog on Kittylog](https://kittylog.app/c/mpfaffenberger/code_puppy)

## Usage

### Adding Models from models.dev 🆕

While there are several models configured right out of the box from providers like Synthetic, Cerebras, OpenAI, Google, and Anthropic, Code Puppy integrates with [models.dev](https://models.dev) to let you browse and add models from **65+ providers** with a single command:

```bash
/add_model
```

This opens an interactive TUI where you can:
- **Browse providers** - See all available AI providers (OpenAI, Anthropic, Groq, Mistral, xAI, Cohere, Perplexity, DeepInfra, and many more)
- **Preview model details** - View capabilities, pricing, context length, and features
- **One-click add** - Automatically configures the model with correct endpoints and API keys

#### Live API with Offline Fallback

The `/add_model` command fetches the latest model data from models.dev in real-time. If the API is unavailable, it falls back to a bundled database:

```
📡 Fetched latest models from models.dev     # Live API
📦 Using bundled models database              # Offline fallback
```

#### Supported Providers

Code Puppy integrates with https://models.dev giving you access to 65 providers and >1000 different model offerings.

There are **39+ additional providers** that already have OpenAI-compatible APIs configured in models.dev!

These providers are automatically configured with correct OpenAI-compatible endpoints, but have **not** been tested thoroughly:

| Provider | Endpoint | API Key Env Var |
|----------|----------|----------------|
| **xAI** (Grok) | `https://api.x.ai/v1` | `XAI_API_KEY` |
| **Groq** | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| **Mistral** | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` |
| **Together AI** | `https://api.together.xyz/v1` | `TOGETHER_API_KEY` |
| **Perplexity** | `https://api.perplexity.ai` | `PERPLEXITY_API_KEY` |
| **DeepInfra** | `https://api.deepinfra.com/v1/openai` | `DEEPINFRA_API_KEY` |
| **Cohere** | `https://api.cohere.com/compatibility/v1` | `COHERE_API_KEY` |
| **AIHubMix** | `https://aihubmix.com/v1` | `AIHUBMIX_API_KEY` |

#### Smart Warnings

- **⚠️ Unsupported Providers** - Providers like Amazon Bedrock and Google Vertex that require special authentication are clearly marked
- **⚠️ No Tool Calling** - Models without tool calling support show a big warning since they can't use Code Puppy's file/shell tools

### Durable Execution

Code Puppy now supports **[DBOS](https://github.com/dbos-inc/dbos-transact-py)** durable execution.

When enabled, every agent is automatically wrapped as a `DBOSAgent`, checkpointing key interactions (including agent inputs, LLM responses, MCP calls, and tool calls) in a database for durability and recovery.

You can toggle DBOS via either of these options:

- CLI config (persists): `/set enable_dbos false` to disable (enabled by default)


Config takes precedence if set; otherwise the environment variable is used.

### Configuration

The following environment variables control DBOS behavior:
- `DBOS_CONDUCTOR_KEY`: If set, Code Puppy connects to the [DBOS Management Console](https://console.dbos.dev/). Make sure you first register an app named `dbos-code-puppy` on the console to generate a Conductor key. Default: `None`.
- `DBOS_LOG_LEVEL`: Logging verbosity: `CRITICAL`, `ERROR`, `WARNING`, `INFO`, or `DEBUG`. Default: `ERROR`.
- `DBOS_SYSTEM_DATABASE_URL`: Database URL used by DBOS. Can point to a local SQLite file or a Postgres instance. Example: `postgresql://postgres:dbos@localhost:5432/postgres`. Default: `dbos_store.sqlite` file in the config directory.
- `DBOS_APP_VERSION`: If set, Code Puppy uses it as the [DBOS application version](https://docs.dbos.dev/architecture#application-and-workflow-versions) and automatically tries to recover pending workflows for this version. Default: Code Puppy version + Unix timestamp in millisecond (disable automatic recovery).

### Custom Commands
Create markdown files in `.claude/commands/`, `.github/prompts/`, or `.agents/commands/` to define custom slash commands. The filename becomes the command name and the content runs as a prompt.

```bash
# Create a custom command
echo "# Code Review

Please review this code for security issues." > .claude/commands/review.md

# Use it in Code Puppy
/review with focus on authentication
```

## ⚡ Elixir-Native Runtime & Acceleration

Code Puppy is **Elixir-native by default**. There is no separate legacy Python-led
"native acceleration" layer anymore; the BEAM runtime owns the fast path:

| Capability | Current owner | Python needed? |
|------------|---------------|----------------|
| `message_core` | Elixir (`MessageCore`) | No |
| `file_ops` | Elixir (`FileOps`) | No |
| `repo_index` | Elixir repo/index services | No |
| `parse` | Elixir (`CodePuppyControl.Parsing.Parser`) | No |
| agents / tools / sessions | Elixir runtime | No on the default path |
| legacy Python plugins/agents | Python bridge | Yes, explicit bridge mode only |

**Architecture (default path):**
```
┌─────────────────────────────────────────────────┐
│              Elixir-native Runtime              │
│   CodePuppyControl (BEAM/OTP)                   │
│   • Agent loop, sessions, CLI/TUI coordination  │
│   • Message processing & pruning                │
│   • Token estimation                            │
│   • File operations (list, read, grep)          │
│   • Parsing / symbols / code context            │
│   • Session serialization                       │
│   • Scheduler (Oban)                            │
│   • Model registry & provider clients           │
└──────────────────────┬──────────────────────────┘
                       │ optional JSON-RPC bridge
┌──────────────────────▼──────────────────────────┐
│          Optional Python Compatibility Layer     │
│   Legacy `code-puppy` CLI, PyPI package,         │
│   Python plugins/agents, explicit bridge mode    │
└─────────────────────────────────────────────────┘
```

### Runtime Selection

| Need | Command / setting |
|------|-------------------|
| **Default daily driver** | **Burrito `code_puppy_control_*` native binary** (recommended) |
| Force Elixir | `PUP_RUNTIME=elixir ./pup` |
| Dev / smoke testing | `./pup` escript (degraded: no Repo/Oban/Endpoint) |
| Explicit Python bridge | `PUP_RUNTIME=python ./pup` or `./pup --bridge-mode` |
| Legacy Python/PyPI CLI | `uvx --from codepp code-puppy` |

`PUP_PYTHON_WORKER_SCRIPT` is **not** required for normal Elixir use. Set it
only when intentionally running Python bridge mode and the worker script cannot
otherwise be configured.

The old Fast Puppy profile UI is historical. If `/fast_puppy` appears in an
older compatibility shell, treat it as a status stub — not as the runtime
control surface. Use `PUP_RUNTIME` / `--bridge-mode` for explicit routing.

### Python Compatibility Opt-Outs

Legacy/PyPI users can still disable Elixir bridge auto-start in
`~/.code_puppy/puppy.cfg` when running the Python compatibility CLI:

```ini
enable_elixir_control=false
```

### 🚀 Python 3.14 Free-Threaded Support (Legacy/Bridge Mode)

**Code Puppy's Python compatibility path is Python 3.14 ready!** Use this when you explicitly run the legacy Python CLI, Python bridge, or Python plugins/agents.

| Python Version | GIL Status | Parallelism |
|----------------|------------|-------------|
| Python 3.14 | Standard GIL | Full functionality, standard concurrency |
| **Python 3.14t** | **Production free-threading** | **True parallel execution across cores** |

#### Running with Free-Threading

```bash
# Option 1: Use the free-threaded Python 3.14 interpreter directly
python3.14t -m code_puppy

# Option 2: Set the environment variable before launch
PYTHON_GIL=0 code-puppy

# Option 3: Set in puppy.cfg (advisory — logged at startup)
free_threading=true
```

#### What You Get with Python 3.14 Free-Threading

- **True Parallelism**: Multiple threads can execute Python bytecode simultaneously
- **Pack Parallelism Boost**: Run 8+ agents truly in parallel, not just concurrently
- **No Code Changes Required**: Works transparently with existing Code Puppy features

#### Checking Your Setup

```bash
# Verify free-threading is active
python3.14t -c "import sys; print(f'Free-threading: {not sys._is_gil_enabled()}')"

# Check the Python compatibility CLI starts
code-puppy --help
```

## Requirements

- **Burrito native binary** (recommended): No runtime dependencies — Erlang/Elixir/Python are bundled in the binary
- **Escript** (dev/smoke): Erlang/OTP 26+ on the target machine
- Python 3.14+ **only** for the legacy `code-puppy`/PyPI compatibility path, Python plugins/agents, or explicit `--bridge-mode` / `PUP_RUNTIME=python`
- API keys: OpenAI (GPT models), Cerebras, Anthropic (Claude models), or Ollama endpoint

## Agent Rules
We support AGENT.md files for defining coding standards and styles that your code should comply with. These rules can cover various aspects such as formatting, naming conventions, and even design guidelines.

For examples and more information about agent rules, visit [https://agent.md](https://agent.md)

## Using MCP Servers for External Tools

Use the `/mcp` command to manage MCP (list, start, stop, status, etc.)

## Security Model: Shell Commands and Plugins

### Shell command paths

Code Puppy has **two distinct shell execution paths**:

1. **Agent tool path** — `agent_run_shell_command`
   - Used by agents and sub-agents
   - Flows through the `run_shell_command` callback hook
   - Can be governed by the `shell_safety` plugin and `PolicyEngine`
   - In non-yolo mode, also supports interactive user confirmation

2. **Direct shell passthrough** — `!<command>`
   - Runs a shell command immediately from the user prompt
   - **Bypasses the AI agent entirely**
   - **Does not use the agent/tool safety pipeline**
   - Should be treated like running the command directly in your terminal

If you want Code Puppy safety and policy checks, use the agent tool path rather than `!<command>`.
If you use `!<command>`, you are explicitly choosing direct local execution.

### Plugin trust boundary

Built-in plugins ship with Code Puppy, but **user plugins are fully trusted local code**.
If you enable the Python compatibility/plugin bridge, Python in `~/.code_puppy/plugins/` is imported and executed during plugin discovery.
That means user plugins can read files, execute processes, modify configuration, and access any data the local Python bridge process can access.

Only install or keep user plugins you trust at the same level as other local developer tooling.

### Safe-mode expectations

At the moment, Code Puppy does **not** provide a fully isolated "safe mode" for user plugins.
If you need a more locked-down session, the safest current approach is:

- remove or rename untrusted directories under `~/.code_puppy/plugins/`
- avoid `!<command>` passthrough for sensitive workflows
- prefer non-yolo execution so agent tool calls can be reviewed
- use policy rules for `agent_run_shell_command` where appropriate

A future hardening direction is an explicit user-plugin disable switch and/or policy-aware shell passthrough mode.

## Round Robin Model Distribution

Code Puppy supports **Round Robin model distribution** to help you overcome rate limits and distribute load across multiple AI models. This feature automatically cycles through configured models with each request, maximizing your API usage while staying within rate limits.

### Configuration
Add a round-robin model configuration to your `~/.code_puppy/extra_models.json` file:

```bash
export CEREBRAS_API_KEY1=csk-...
export CEREBRAS_API_KEY2=csk-...
export CEREBRAS_API_KEY3=csk-...

```

```json
{
  "qwen1": {
    "type": "cerebras",
    "name": "qwen-3-coder-480b",
    "custom_endpoint": {
      "url": "https://api.cerebras.ai/v1",
      "api_key": "$CEREBRAS_API_KEY1"
    },
    "context_length": 131072
  },
  "qwen2": {
    "type": "cerebras",
    "name": "qwen-3-coder-480b",
    "custom_endpoint": {
      "url": "https://api.cerebras.ai/v1",
      "api_key": "$CEREBRAS_API_KEY2"
    },
    "context_length": 131072
  },
  "qwen3": {
    "type": "cerebras",
    "name": "qwen-3-coder-480b",
    "custom_endpoint": {
      "url": "https://api.cerebras.ai/v1",
      "api_key": "$CEREBRAS_API_KEY3"
    },
    "context_length": 131072
  },
  "cerebras_round_robin": {
    "type": "round_robin",
    "models": ["qwen1", "qwen2", "qwen3"],
    "rotate_every": 5
  }
}
```

Then just use /model and tab to select your round-robin model!

The `rotate_every` parameter controls how many requests are made to each model before rotating to the next one. In this example, the round-robin model will use each Qwen model for 5 consecutive requests before moving to the next model in the sequence.

---

## Create your own Agent!!!

Code Puppy features a flexible agent system that allows you to work with specialized AI assistants tailored for different coding tasks. The default runtime is Elixir-native; custom JSON agents remain the recommended user-facing extension path, and legacy Python agents remain available through the compatibility bridge.

## Quick Start

### Check Current Agent
```bash
/agent
```
Shows current active agent and all available agents

### Switch Agent
```bash
/agent <agent-name>
```
Switches to the specified agent

### Create New Agent
```bash
/agent agent-creator
```
Switches to the Agent Creator for building custom agents

### Truncate Message History
```bash
/truncate <N>
```
Truncates the message history to keep only the N most recent messages while protecting the first (system) message. For example:
```bash
/truncate 20
```
Would keep the system message plus the 19 most recent messages, removing older ones from the history.

This is useful for managing context length when you have a long conversation history but only need the most recent interactions.

## Available Agents

### Code-Puppy 🐶 (Default)
- **Name**: `code-puppy`
- **Specialty**: General-purpose coding assistant
- **Personality**: Playful, sarcastic, pedantic about code quality
- **Tools**: Full access to all tools
- **Best for**: All coding tasks, file management, execution
- **Principles**: Clean, concise code following YAGNI, SRP, DRY principles
- **File limit**: Max 600 lines per file (enforced!)

### Agent Creator 🏗️
- **Name**: `agent-creator`
- **Specialty**: Creating custom JSON agent configurations
- **Tools**: File operations, reasoning
- **Best for**: Building new specialized agents
- **Features**: Schema validation, guided creation process

## Agent Types

### Built-in and Compatibility Agents
Elixir-native built-in agents run through `CodePuppyControl` by default. Legacy Python agents remain supported for compatibility:
- Python compatibility agents are discovered from the `code_puppy/agents/` directory when the Python bridge is enabled
- They inherit from the legacy `BaseAgent` class
- They are useful for existing Python integrations, plugins, and troubleshooting
- Examples: `code-puppy`, `agent-creator`

### JSON Agents
User-created agents defined in JSON files:
- Stored in user's agents directory
- Easy to create, share, and modify
- Schema-validated configuration
- Custom system prompts and tool access

## Creating Custom JSON Agents

### Using Agent Creator (Recommended)

1. **Switch to Agent Creator**:
   ```bash
   /agent agent-creator
   ```

2. **Request agent creation**:
   ```
   I want to create a Python tutor agent
   ```

3. **Follow guided process** to define:
   - Name and description
   - Available tools
   - System prompt and behavior
   - Custom settings

4. **Test your new agent**:
   ```bash
   /agent your-new-agent-name
   ```

### Manual JSON Creation

Create JSON files in your agents directory following this schema:

```json
{
  "name": "agent-name",              // REQUIRED: Unique identifier (kebab-case)
  "display_name": "Agent Name 🤖",   // OPTIONAL: Pretty name with emoji
  "description": "What this agent does", // REQUIRED: Clear description
  "system_prompt": "Instructions...",    // REQUIRED: Agent instructions
  "tools": ["tool1", "tool2"],        // REQUIRED: Array of tool names
  "user_prompt": "How can I help?",     // OPTIONAL: Custom greeting
  "tools_config": {                    // OPTIONAL: Tool configuration
    "timeout": 60
  }
}
```

#### Required Fields
- **`name`**: Unique identifier (kebab-case, no spaces)
- **`description`**: What the agent does
- **`system_prompt`**: Agent instructions (string or array)
- **`tools`**: Array of available tool names

#### Optional Fields
- **`display_name`**: Pretty display name (defaults to title-cased name + 🤖)
- **`user_prompt`**: Custom user greeting
- **`tools_config`**: Tool configuration object

## Available Tools

Agents can access these tools based on their configuration:

- **`list_files`**: Directory and file listing
- **`read_file`**: File content reading
- **`grep`**: Text search across files
- **`create_file`**: Create new files or overwrite existing ones
- **`replace_in_file`**: Targeted text replacements in existing files
- **`delete_snippet`**: Remove a text snippet from a file
- **`delete_file`**: File deletion
- **`agent_run_shell_command`**: Shell command execution
- **`agent_share_your_reasoning`**: Share reasoning with user

### Tool Access Examples
- **Read-only agent**: `["list_files", "read_file", "grep"]`
- **File editor agent**: `["list_files", "read_file", "create_file", "replace_in_file"]`
- **Full access agent**: All tools (like Code-Puppy)

## System Prompt Formats

### String Format
```json
{
  "system_prompt": "You are a helpful coding assistant that specializes in Python development."
}
```

### Array Format (Recommended)
```json
{
  "system_prompt": [
    "You are a helpful coding assistant.",
    "You specialize in Python development.",
    "Always provide clear explanations.",
    "Include practical examples in your responses."
  ]
}
```

## Example JSON Agents

### Python Tutor
```json
{
  "name": "python-tutor",
  "display_name": "Python Tutor 🐍",
  "description": "Teaches Python programming concepts with examples",
  "system_prompt": [
    "You are a patient Python programming tutor.",
    "You explain concepts clearly with practical examples.",
    "You help beginners learn Python step by step.",
    "Always encourage learning and provide constructive feedback."
  ],
  "tools": ["read_file", "create_file", "replace_in_file", "agent_share_your_reasoning"],
  "user_prompt": "What Python concept would you like to learn today?"
}
```

### Code Reviewer
```json
{
  "name": "code-reviewer",
  "display_name": "Code Reviewer 🔍",
  "description": "Reviews code for best practices, bugs, and improvements",
  "system_prompt": [
    "You are a senior software engineer doing code reviews.",
    "You focus on code quality, security, and maintainability.",
    "You provide constructive feedback with specific suggestions.",
    "You follow language-specific best practices and conventions."
  ],
  "tools": ["list_files", "read_file", "grep", "agent_share_your_reasoning"],
  "user_prompt": "Which code would you like me to review?"
}
```

### DevOps Helper
```json
{
  "name": "devops-helper",
  "display_name": "DevOps Helper ⚙️",
  "description": "Helps with Docker, CI/CD, and deployment tasks",
  "system_prompt": [
    "You are a DevOps engineer specialized in containerization and CI/CD.",
    "You help with Docker, Kubernetes, GitHub Actions, and deployment.",
    "You provide practical, production-ready solutions.",
    "You always consider security and best practices."
  ],
  "tools": [
    "list_files",
    "read_file",
    "create_file",
    "replace_in_file",
    "agent_run_shell_command",
    "agent_share_your_reasoning"
  ],
  "user_prompt": "What DevOps task can I help you with today?"
}
```

## File Locations

### JSON Agents Directory
- **All platforms**: `~/.code_puppy/agents/`

### Legacy Python Agents Directory
- **Compatibility path**: `code_puppy/agents/` (in the Python package)

## Best Practices

### Naming
- Use kebab-case (hyphens, not spaces)
- Be descriptive: "python-tutor" not "tutor"
- Avoid special characters

### System Prompts
- Be specific about the agent's role
- Include personality traits
- Specify output format preferences
- Use array format for multi-line prompts

### Tool Selection
- Only include tools the agent actually needs
- Most agents need `agent_share_your_reasoning`
- File manipulation agents need `read_file`, `create_file`, `replace_in_file`
- Note: `"edit_file"` still works in tool lists (auto-expands to the three individual tools)
- Research agents need `grep`, `list_files`

### Display Names
- Include relevant emoji for personality
- Make it friendly and recognizable
- Keep it concise

## System Architecture

### Agent Discovery
The system automatically discovers agents by:
1. **Elixir-native agents**: Registering built-ins through the default `CodePuppyControl` runtime
2. **JSON Agents**: Scanning the user's agents directory for `*-agent.json` files
3. **Legacy Python agents**: Scanning `code_puppy/agents/` for classes inheriting from `BaseAgent` when the Python bridge is enabled
4. Instantiating and registering discovered agents

### JSONAgent Implementation
On the legacy Python compatibility path, JSON agents are powered by the `JSONAgent` class (`code_puppy/agents/json_agent.py`):
- Inherits from `BaseAgent` for compatibility with the existing agent interface
- Loads configuration from JSON files with robust validation
- Supports all BaseAgent features (tools, prompts, settings)
- Cross-platform user directory support
- Built-in error handling and schema validation

### BaseAgent Interface
Elixir-native agents, JSON agents, and legacy Python agents expose the same user-facing interface:
- `name`: Unique identifier
- `display_name`: Human-readable name with emoji
- `description`: Brief description of purpose
- `get_system_prompt()`: Returns agent-specific system prompt
- `get_available_tools()`: Returns list of tool names

### Agent Manager Integration
On the legacy Python compatibility path, `agent_manager.py` provides:
- Unified registry for Python compatibility agents and JSON agents
- Seamless switching between agent types
- Configuration persistence across sessions
- Automatic caching for performance

### System Integration
- **Command Interface**: `/agent` command works with all agent types
- **Tool Filtering**: Dynamic tool access control per agent
- **Main Agent System**: Loads and manages both agent types
- **Cross-Platform**: Consistent behavior across all platforms

## Adding Legacy Python Agents

Prefer JSON agents for user customization. Create a Python agent only when you specifically need the legacy Python compatibility path or Python internals:

1. Create file in `code_puppy/agents/` (e.g., `my_agent.py`)
2. Implement class inheriting from `BaseAgent`
3. Define required properties and methods
4. Agent will be automatically discovered

Example implementation:

```python
from .base_agent import BaseAgent

class MyCustomAgent(BaseAgent):
    @property
    def name(self) -> str:
        return "my-agent"

    @property
    def display_name(self) -> str:
        return "My Custom Agent ✨"

    @property
    def description(self) -> str:
        return "A custom agent for specialized tasks"

    def get_system_prompt(self) -> str:
        return "Your custom system prompt here..."

    def get_available_tools(self) -> list[str]:
        return [
            "list_files",
            "read_file",
            "grep",
            "create_file",
            "replace_in_file",
            "delete_snippet",
            "delete_file",
            "agent_run_shell_command",
            "agent_share_your_reasoning"
        ]
```

## Troubleshooting

### Agent Not Found
- Ensure JSON file is in correct directory
- Check JSON syntax is valid
- Restart Code Puppy or clear agent cache
- Verify filename ends with `-agent.json`

### Validation Errors
- Use Agent Creator for guided validation
- Check all required fields are present
- Verify tool names are correct
- Ensure name uses kebab-case

### Permission Issues
- Make sure agents directory is writable
- Check file permissions on JSON files
- Verify directory path exists

## Advanced Features

### Tool Configuration
```json
{
  "tools_config": {
    "timeout": 120,
    "max_retries": 3
  }
}
```

### Multi-line System Prompts
```json
{
  "system_prompt": [
    "Line 1 of instructions",
    "Line 2 of instructions",
    "Line 3 of instructions"
  ]
}
```

## Future Extensibility

The agent system supports future expansion:

- **Specialized Agents**: Code reviewers, debuggers, architects
- **Domain-Specific Agents**: Web dev, data science, DevOps, mobile
- **Personality Variations**: Different communication styles
- **Context-Aware Agents**: Adapt based on project type
- **Team Agents**: Shared configurations for coding standards
- **Plugin System**: Community-contributed agents

## Benefits of JSON Agents

1. **Easy Customization**: Create agents without Python knowledge
2. **Team Sharing**: JSON agents can be shared across teams
3. **Rapid Prototyping**: Quick agent creation for specific workflows
4. **Version Control**: JSON agents are git-friendly
5. **Built-in Validation**: Schema validation with helpful error messages
6. **Cross-Platform**: Works consistently across all platforms
7. **Backward Compatible**: Doesn't affect existing legacy Python agents

## Implementation Details

### Files in System
- **Core Implementation (Python compatibility path)**: `code_puppy/agents/json_agent.py`
- **Agent Discovery (Python compatibility path)**: Integrated in `code_puppy/agents/agent_manager.py`
- **Command Interface**: Works through existing `/agent` command
- **Testing**: Elixir test suite (see `elixir/code_puppy_control/test/`)

### JSON Agent Loading Process
1. System scans `~/.code_puppy/agents/` for `*-agent.json` files
2. `JSONAgent` class loads and validates each JSON configuration
3. Agents are registered in unified agent registry
4. Users can switch to JSON agents via `/agent <name>` command
5. Tool access and system prompts work consistently with built-in and legacy Python agents

### Error Handling
- Invalid JSON syntax: Clear error messages with line numbers
- Missing required fields: Specific field validation errors
- Invalid tool names: Warning with list of available tools
- File permission issues: Helpful troubleshooting guidance

## Future Possibilities

- **Agent Templates**: Pre-built JSON agents for common tasks
- **Visual Editor**: GUI for creating JSON agents
- **Hot Reloading**: Update agents without restart
- **Agent Marketplace**: Share and discover community agents
- **Enhanced Validation**: More sophisticated schema validation
- **Team Agents**: Shared configurations for coding standards

## Contributing

### Sharing JSON Agents
1. Create and test your agent thoroughly
2. Ensure it follows best practices
3. Submit a pull request with agent JSON
4. Include documentation and examples
5. Test across different platforms

### Legacy Python Agent Contributions
1. Follow existing code style
2. Include comprehensive tests
3. Document the agent's purpose and usage
4. Submit pull request for review
5. Ensure backward compatibility

### Agent Templates
Consider contributing agent templates for:
- Code reviewers and auditors
- Language-specific tutors
- DevOps and deployment helpers
- Documentation writers
- Testing specialists

---

# Code Puppy Privacy Commitment

**Zero-compromise privacy policy. Always.**

Unlike other Agentic Coding software, there is no corporate or investor backing for this project, which means **zero pressure to compromise our principles for profit**. This isn't just a nice-to-have feature – it's fundamental to the project's DNA.

### What Code Puppy _absolutely does not_ collect:
- ❌ **Zero telemetry** – no usage analytics, crash reports, or behavioral tracking
- ❌ **Zero prompt logging** – your code, conversations, or project details are never stored
- ❌ **Zero behavioral profiling** – we don't track what you build, how you code, or when you use the tool
- ❌ **Zero third-party data sharing** – your information is never sold, traded, or given away

### What data flows where:
- **LLM Provider Communication**: Your prompts are sent directly to whichever LLM provider you've configured (OpenAI, Anthropic, local models, etc.) – this is unavoidable for AI functionality
- **Complete Local Option**: Run your own VLLM/SGLang/Llama.cpp server locally → **zero data leaves your network**. Configure this with `~/.code_puppy/extra_models.json`
- **Direct Developer Contact**: All feature requests, bug reports, and discussions happen directly with me – no middleman analytics platforms or customer data harvesting tools

### Our privacy-first architecture:
Code Puppy is designed with privacy-by-design principles. Every feature has been evaluated through a privacy lens, and every integration respects user data sovereignty. When you use Code Puppy, you're not the product – you're just a developer getting things done.

**This commitment is enforceable because it's structurally impossible to violate it.** No external pressures, no investor demands, no quarterly earnings targets to hit. Just solid code that respects your privacy.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
