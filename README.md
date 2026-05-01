> **Note:** As of Phase H cutover, Code Puppy runs on **Elixir only**.
> The Python codebase has been removed. See ADR-004 for migration history.

<div align="center">

**🐶✨The sassy AI code agent that makes IDEs look outdated** ✨🐶

[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

[![100% Open Source](https://img.shields.io/badge/100%25-Open%20Source-blue?style=for-the-badge)](https://github.com/mpfaffenberger/code_puppy)

[![100% privacy](https://img.shields.io/badge/FULL-Privacy%20commitment-blue?style=for-the-badge)](https://github.com/mpfaffenberger/code_puppy/blob/main/README.md#code-puppy-privacy-commitment)

[![GitHub stars](https://img.shields.io/github/stars/mpfaffenberger/code_puppy?style=for-the-badge&logo=github)](https://github.com/mpfaffenberger/code_puppy/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/mpfaffenberger/code_puppy?style=for-the-badge&logo=github)](https://github.com/mpfaffenberger/code_puppy/network)

[![Discord](https://img.shields.io/badge/Discord-Community-purple?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/eAGdE4J7Ca)
[![Docs](https://img.shields.io/badge/Read-The%20Docs-blue?style=for-the-badge&logo=readthedocs)](https://code-puppy.dev)

**[⭐ Star this repo if you hate expensive IDEs! ⭐](#quick-start)**

*"Who needs an IDE when you have 1024 angry puppies?"* - Someone, probably.

</div>

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
| ⚡ Pure Elixir Runtime | Full Elixir/BEAM backend for all operations | 10-50x faster |
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

## Quick Start

### From Source (Elixir)

```bash
# Clone and build
git clone https://github.com/mpfaffenberger/code_puppy.git
cd code_puppy/elixir/code_puppy_control
mix deps.get
mix compile

# Run
mix run --no-halt
```

### Local Development

```bash
./scripts/run_dev.sh           # start dev services
./scripts/run_dev.sh --help    # see options
```

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

## ⚡ Architecture

Code Puppy runs on a **pure Elixir/BEAM runtime**:

```
┌─────────────────────────────────────────────────┐
│              CodePuppyControl (BEAM/OTP)        │
│   • Message processing & pruning               │
│   • Token estimation                           │
│   • File operations (list, read, grep)         │
│   • Tree-sitter parsing                        │
│   • Session serialization (MessagePack)        │
│   • Agent session management                   │
│   • Scheduler (Oban)                           │
│   • Model registry                             │
│   • WebSocket/terminal interface               │
│   • Plugin system (callback hooks)             │
└─────────────────────────────────────────────────┘
```

### `/fast_puppy` Commands

```
/fast_puppy                        → show status for all capabilities
/fast_puppy status                 → detailed per-capability status
```

## Requirements

- Erlang/OTP 27+
- Elixir 1.18+
- OpenAI API key (for GPT models)
- Cerebras API key (for Cerebras models)
- Anthropic key (for Claude models)
- Ollama endpoint available

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
   - Can be governed by security plugins
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
Any Elixir in `~/.code_puppy/plugins/` is loaded and executed during plugin discovery.
That means user plugins can read files, execute processes, modify configuration, and access any data your local system can access.

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
