# Fork Changelog

This document summarizes the key differences and enhancements in this fork
relative to the upstream [Code Puppy](https://github.com/mpfaffenberger/code_puppy) project.

For per-commit detail, see `git log`.

## Key Fork Differences

### Architecture & Runtime

- **Elixir/Phoenix control plane** (`elixir/code_puppy_control/`) replaces the
  Python FastAPI control plane for session management, scheduling, and
  orchestration. The Python runtime remains for agent execution and tooling.
- **Dual CLI**: The Elixir escript (`pup`) and Python console script
  (`code-puppy`) coexist; `--bridge-mode` on the Elixir CLI delegates to the
  Python runtime.
- **Burrito single-binary packaging** for macOS, Linux, and Windows — no
  Erlang/Elixir installation required on target machines.

### Python Distribution

- Published to PyPI as **`codepp`** (the `code-puppy` name on PyPI belongs to
  upstream). Installed entry points remain `code-puppy`, `pup`, and `gac`.
- Requires **Python 3.14+** (free-threaded builds supported).

### CI & Release

- **GitHub Actions CI** (`ci.yml`): Python lint/test, Elixir format/compile/test,
  Elixir smoke/escript validation on every push/PR.
- **Burrito release workflow** (`burrito-release.yml`): tag-triggered builds on
  3 platforms with GitHub Release + SHA256SUMS.txt.
- **Local release gate** (`scripts/release-gate.sh`): pre-push quality gate
  for Python and Elixir lanes.
- **Python package smoke** (`scripts/python-package-smoke.sh`): validates
  wheel build, install, and entry points from a clean venv.

### Plugins & Agents

- 48 plugins, 18+ agents, 150+ merged feature branches.
- Agent names aligned with current catalogue (`elixir-code-critic`, `qa-kitten`).
- Plugin system uses `code_puppy/plugins/` + hook callbacks.

### Security

- AES-256-GCM credential encryption with per-installation machine secrets.
- OAuth integration (ChatGPT, Claude) with PKCE flow.
- SQLite database isolation (ADR-003: separate from Python `~/.code_puppy/`).

### Free-Threading

- Python 3.14t free-threaded mode supported for true parallel execution.
- Pack parallelism boost with GIL-disabled interpreter.

---

For the upstream project's changelog, see the
[upstream repository](https://github.com/mpfaffenberger/code_puppy).
