#!/usr/bin/env bash
# no-python-refs-guard.sh — prevent reintroduction of legacy Python runtime/tooling refs
#
# Scans tracked files for references to legacy Python runtime env vars,
# bridge-mode flags, and Python worker script config. These were removed
# when the Python product was deleted (code-puppy-3o7.8) and the runtime
# became native-only (code-puppy-3o7.6).
#
# This guard fails if any NEW references to these patterns appear outside
# the explicit allowlist (code-puppy-3o7.5.5).
#
# Forbidden patterns:
#   PUP_RUNTIME          (runtime selector — native-only no longer uses this)
#   --bridge-mode        (Python bridge activation flag)
#   PythonWorker         (Elixir bridge module — deleted)
#   Run.Executor.Python  (Elixir executor module — deleted)
#   PUP_PYTHON_WORKER_SCRIPT  (worker script env var)
#   PYTHON_WORKER_SCRIPT      (worker script env var, legacy name)
#
# Allowlisted paths (legitimate references):
#   - docs/adr/ — ADR documents reference historical decisions
#   - docs/release/python-free-runtime-guarantee* — Python-free guarantee docs
#   - docs/native-elixir-python-dependency-audit* — audit document
#   - issues.jsonl — historical issue tracker
#   - Parser source files: python_lexer.ex, python_parser.ex, .xrl, .yrl
#   - Parser/lexer tests: python_lexer_test.exs, python_parser_test.exs
#   - Smoke tests: smoke_test.exs (tests native-only behavior)
#   - python_free_runtime_test.exs (tests Python-free guarantee)
#   - native_parity_smoke_test.exs (tests native parity)
#   - This guard script (self-referencing)
#   - code_puppy_phase_c_e2e_test.exs (verifies no PythonWorker dependency)
#   - run_manager_test.exs (tests no-Python-worker behavior)
#   - smoke-burrito-native.sh (sanitizes Python env vars)
#   - AGENTS.md (system prompt, documents compatibility paths)
#   - CONTRIBUTING.md (project conventions, references compatibility)
#
# Exit codes:
#   0  guard passed — no forbidden refs outside allowlist
#   1  guard failed — forbidden refs detected outside allowlist
#
# Refs: code-puppy-3o7.5.5

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
FAILED=0
VIOLATIONS=()

info()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ── Locate repo root ───────────────────────────────────────────────────────
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "${REPO_ROOT}" ]]; then
  error "could not locate git repository root"
  exit 1
fi

cd "${REPO_ROOT}"

# ── Forbidden patterns ──────────────────────────────────────────────────────
PATTERNS=(
  'PUP_RUNTIME'
  '--bridge-mode'
  'PythonWorker'
  'Run\.Executor\.Python'
  'PUP_PYTHON_WORKER_SCRIPT'
  'PYTHON_WORKER_SCRIPT'
)

# ── Allowlisted file paths (grep -E patterns matched against full path) ────
ALLOWLIST_PATHS=(
  '^docs/adr/'
  '^docs/release/python-free-runtime-guarantee'
  '^docs/native-elixir-python-dependency-audit'
  '^issues\.jsonl$'
  'python_lexer\.ex$'
  'python_parser\.ex$'
  'python_lexer\.xrl$'
  'python_parser\.yrl$'
  'python_lexer_test\.exs$'
  'python_parser_test\.exs$'
  'cli/smoke_test\.exs$'
  'python_free_runtime_test\.exs$'
  'native_parity_smoke_test\.exs$'
  'code_puppy_phase_c_e2e_test\.exs$'
  'run_manager_test\.exs$'
  'smoke-burrito-native\.sh$'
  'ci-guards/no-python-refs-guard\.sh$'
  '^AGENTS\.md$'
  '^CONTRIBUTING\.md$'
)

# ── Helper: check if a file path is allowlisted ────────────────────────────
is_allowlisted() {
  local filepath="$1"

  for pattern in "${ALLOWLIST_PATHS[@]}"; do
    if echo "${filepath}" | grep -qE "${pattern}"; then
      return 0
    fi
  done

  return 1
}

# ── Get all tracked text files ──────────────────────────────────────────────
# Use git ls-files + file command to only scan text files (skip binaries).
# git grep is more efficient but we need per-file allowlisting.

TRACKED_FILES="$(git ls-files -z 2>/dev/null | xargs -0 file --mime-type -f - 2>/dev/null \
  | grep ': text/' \
  | cut -d: -f1 \
  || true)"

if [[ -z "${TRACKED_FILES}" ]]; then
  info "no tracked text files to scan"
  exit 0
fi

# ── Scan each file for each pattern ─────────────────────────────────────────
for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r filepath; do
    # Skip allowlisted files
    if is_allowlisted "${filepath}"; then
      continue
    fi

    # Check if the file contains the forbidden pattern
    if git grep -q -- "${pattern}" -- "${filepath}" 2>/dev/null; then
      # Get the matching lines for the report
      MATCHES="$(git grep -n -- "${pattern}" -- "${filepath}" 2>/dev/null | head -3 || true)"
      VIOLATIONS+=("${filepath}: ${pattern}")
      error "FORBIDDEN REF: ${filepath} contains '${pattern}'"
      while IFS= read -r match; do
        error "  ${match}"
      done <<< "${MATCHES}"
    fi
  done <<< "${TRACKED_FILES}"
done

# ── Summary ─────────────────────────────────────────────────────────────────
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  info "GUARD PASSED — no forbidden Python runtime/tooling refs outside allowlist"
else
  error "GUARD FAILED — ${#VIOLATIONS[@]} file(s) with forbidden refs outside allowlist"
  error ""
  error "If these references are legitimate, add the file path to ALLOWLIST_PATHS"
  error "in scripts/ci-guards/no-python-refs-guard.sh"
  FAILED=1
fi

exit ${FAILED}
