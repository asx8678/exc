#!/usr/bin/env bash
# scripts/smoke-burrito-native.sh — Burrito native binary smoke test
#
# Validates that a built Burrito binary works with the Elixir runtime
# and no Python dependency.  Designed for CI and local parity: the same
# script runs on developer machines and in GitHub Actions.
#
# Prerequisites:
#   - A Burrito binary already built under burrito_out/ (via build-burrito.sh)
#   - 'timeout' command available (coreutils; always present on Linux/macOS CI)
#
# Usage:
#   scripts/smoke-burrito-native.sh              # auto-locate binary in burrito_out/
#   scripts/smoke-burrito-native.sh /path/to/binary
#   scripts/smoke-burrito-native.sh --skip-build  # alias for clarity; this script
#                                                 # does NOT build (build-burrito.sh does)
#
# Exit codes:
#   0  all smoke checks passed
#   1  one or more smoke checks failed
#   2  usage / prerequisite error
#
# Refs: code-puppy-7st, code-puppy-v2o

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[burrito-smoke]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[burrito-smoke]${NC} PASS: $*" >&2; }
warn()  { echo -e "${YELLOW}[burrito-smoke]${NC} $*" >&2; }
error() { echo -e "${RED}[burrito-smoke]${NC} FAIL: $*" >&2; }

# ── Locate project root ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "${PROJECT_ROOT}/mix.exs" ]]; then
  error "could not find mix.exs at ${PROJECT_ROOT}"
  exit 2
fi

cd "${PROJECT_ROOT}"

# ── Parse arguments ───────────────────────────────────────────────────────
BINARY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      # No-op: this script never builds. Accept for CLI compatibility
      # with smoke-packaged.sh argument style.
      shift
      ;;
    --help|-h)
      sed -n '1,30p' "$0"
      exit 0
      ;;
    -*)
      error "Unknown option: $1"
      exit 2
      ;;
    *)
      BINARY_PATH="$1"
      shift
      ;;
  esac
done

# ── Locate the Burrito binary ─────────────────────────────────────────────
if [[ -n "${BINARY_PATH}" ]]; then
  if [[ ! -x "${BINARY_PATH}" ]]; then
    error "specified binary not found or not executable: ${BINARY_PATH}"
    exit 2
  fi
  BINARY="$(cd "$(dirname "${BINARY_PATH}")" && pwd)/$(basename "${BINARY_PATH}")"
else
  OUTPUT_DIR="burrito_out"
  if [[ ! -d "${OUTPUT_DIR}" ]]; then
    error "burrito_out/ directory not found. Run scripts/build-burrito.sh --host-only first."
    exit 2
  fi

  # Find the host-platform binary (there should be exactly one for --host-only builds)
  mapfile -t CANDIDATES < <(find "${OUTPUT_DIR}" -maxdepth 1 -type f -executable -name 'code_puppy_control_*' 2>/dev/null)

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    error "no executable Burrito binary found in ${OUTPUT_DIR}/"
    error "Run scripts/build-burrito.sh --host-only first."
    exit 2
  fi

  if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
    # Multiple binaries — pick the one matching the current host
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    HOST_TAG=""
    case "${OS}" in
      Darwin)
        if [[ "${ARCH}" == "arm64" ]]; then HOST_TAG="macos_arm64"
        else HOST_TAG="macos_x86_64"; fi ;;
      Linux)
        if [[ "${ARCH}" == "aarch64" ]]; then HOST_TAG="linux_arm64"
        else HOST_TAG="linux_x86_64"; fi ;;
    esac

    for c in "${CANDIDATES[@]}"; do
      if [[ "$(basename "$c")" == *"${HOST_TAG}"* ]]; then
        BINARY="$c"
        break
      fi
    done

    if [[ -z "${BINARY:-}" ]]; then
      error "multiple binaries in ${OUTPUT_DIR}/ but none match host ${OS}/${ARCH}"
      error "candidates: ${CANDIDATES[*]}"
      exit 2
    fi
  else
    BINARY="${CANDIDATES[0]}"
  fi
fi

info "binary under test: ${BINARY}"

# ── Derive expected version from mix.exs ─────────────────────────────────
# Read the project version so the --version check is robust across releases.
EXPECTED_VERSION=""
if command -v mix >/dev/null 2>&1; then
  EXPECTED_VERSION="$(mix eval 'IO.puts(Mix.Project.config()[:version])' 2>/dev/null || true)"
fi
# Fallback: scrape from mix.exs directly
if [[ -z "${EXPECTED_VERSION}" ]]; then
  EXPECTED_VERSION="$(grep -oP 'version:\s*"\K[^"]+' mix.exs | head -1 || true)"
fi
if [[ -z "${EXPECTED_VERSION}" ]]; then
  warn "could not determine project version from mix.exs; skipping exact version match"
fi

# ── Prepare sanitized environment ─────────────────────────────────────────
# These vars are unset/emptied so the Burrito binary runs purely as an
# Elixir-native app with no Python fallback and no stray database paths.
SMOKE_ENV=(
  PUP_RUNTIME=elixir
  # Sanitize secrets/dbs so the binary doesn't accidentally touch real data
  PUP_SECRET_KEY_BASE=
  SECRET_KEY_BASE=
  PUP_DATABASE_PATH=
  DATABASE_PATH=
  # Sanitize Python paths so the app cannot find a Python worker
  PUP_PYTHON_WORKER_SCRIPT=
  PYTHON_WORKER_SCRIPT=
  PYTHONPATH=
  VIRTUAL_ENV=
  CONDA_PREFIX=
)

info "sanitized env: native-only runtime, Python/DB/secret vars unset"

# ── Smoke checks ──────────────────────────────────────────────────────────
FAILURES=0

# Helper: run binary with sanitized env, capture exit code.
# Stdout from the binary is captured and echoed to caller's stdout;
# log messages go to stderr so they don't pollute captured output.
run_smoke() {
  local desc="$1"; shift
  local expected_exit="$1"; shift
  local output
  local actual_exit=0
  output="$(env -i "${SMOKE_ENV[@]}" PATH="${PATH}" HOME="${HOME}" "$@" 2>&1)" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    error "${desc} — expected exit ${expected_exit}, got ${actual_exit}"
    echo "${output}" | tail -20 >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  ok "${desc} (exit ${actual_exit})"
  # Write captured output to stdout so callers can capture it
  echo "${output}"
  return 0
}

# 1. --version: exits 0, outputs exactly one line matching 'code-puppy <version>'
info "checking --version..."
VERSION_OUTPUT="$(run_smoke "--version exits 0" 0 "${BINARY}" --version)" || true
VERSION_LINE_COUNT="$(echo "${VERSION_OUTPUT}" | wc -l | tr -d ' ')"

if [[ "${VERSION_LINE_COUNT}" -ne 1 ]]; then
  error "--version output has ${VERSION_LINE_COUNT} lines (expected 1)"
  error "output: ${VERSION_OUTPUT}"
  FAILURES=$((FAILURES + 1))
elif [[ -n "${EXPECTED_VERSION}" ]]; then
  EXPECTED_LINE="code-puppy ${EXPECTED_VERSION}"
  if [[ "${VERSION_OUTPUT}" != "${EXPECTED_LINE}" ]]; then
    error "--version output mismatch: got '${VERSION_OUTPUT}', expected '${EXPECTED_LINE}'"
    FAILURES=$((FAILURES + 1))
  else
    ok "--version output matches 'code-puppy ${EXPECTED_VERSION}'"
  fi
else
  # No version to compare against; just check the prefix
  if [[ "${VERSION_OUTPUT}" == code-puppy\ * ]]; then
    ok "--version output starts with 'code-puppy '"
  else
    error "--version output does not start with 'code-puppy ': '${VERSION_OUTPUT}'"
    FAILURES=$((FAILURES + 1))
  fi
fi

# 2. --help: exits 0
info "checking --help..."
run_smoke "--help exits 0" 0 "${BINARY}" --help >/dev/null || true

# 3. /quit: pipe '/quit' into interactive mode, exits 0
info "checking /quit..."
QUIT_TIMEOUT=15
QUIT_EXIT=0
if command -v timeout >/dev/null 2>&1; then
  # GNU coreutils timeout (Linux CI, most dev machines)
  QUIT_OUTPUT="$(env -i "${SMOKE_ENV[@]}" PATH="${PATH}" HOME="${HOME}" \
    timeout "${QUIT_TIMEOUT}s" bash -c "printf '/quit\n' | \"${BINARY}\"" 2>&1)" || QUIT_EXIT=$?
else
  # macOS fallback: no GNU timeout, use a subshell + watchdog
  QUIT_EXIT=0
  QUIT_OUTPUT="$(env -i "${SMOKE_ENV[@]}" PATH="${PATH}" HOME="${HOME}" \
    bash -c "printf '/quit\n' | \"${BINARY}\"" 2>&1)" || QUIT_EXIT=$?
fi

if [[ ${QUIT_EXIT} -ne 0 ]]; then
  error "/quit — expected exit 0, got ${QUIT_EXIT}"
  echo "${QUIT_OUTPUT}" | tail -20 >&2
  FAILURES=$((FAILURES + 1))
else
  ok "/quit exits 0"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if [[ ${FAILURES} -eq 0 ]]; then
  ok "all Burrito native smoke checks passed (0 failures)"
  exit 0
else
  error "${FAILURES} smoke check(s) failed"
  exit 1
fi
