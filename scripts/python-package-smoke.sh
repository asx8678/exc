#!/usr/bin/env bash
# python-package-smoke.sh — verify the built wheel installs and entry points work
#
# Builds a wheel into a private temp directory, creates a throwaway venv,
# installs the wheel, and verifies the CLI entry points and module help.
#
# Design choices:
#   - Builds into a temp dir (not repo dist/) to keep the worktree clean.
#   - Uses uv for build + venv + install when available; falls back to
#     pip if uv is absent.
#   - Never requires live LLM credentials; entry-point --help is the
#     only invocation.
#   - Cleans up all temp dirs on exit (including on signals).
#   - --skip-build reuses a previously built wheel from the temp dir
#     (useful during iterative debugging).
#
# Usage:
#   scripts/python-package-smoke.sh
#   scripts/python-package-smoke.sh --skip-build
#   scripts/python-package-smoke.sh --help
#
# Exit codes:
#   0  all checks passed
#   1  at least one check failed
#   2  bad arguments or missing prerequisites

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[python-package-smoke]${NC} $*"; }
ok()    { echo -e "${GREEN}[python-package-smoke]${NC} $*"; }
warn()  { echo -e "${YELLOW}[python-package-smoke]${NC} $*"; }
error() { echo -e "${RED}[python-package-smoke]${NC} $*" >&2; }

# ── Parse arguments ───────────────────────────────────────────────────────
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --help|-h)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 2
      ;;
  esac
done

# ── Locate repo root ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  # Fallback: walk up looking for pyproject.toml
  dir="$SCRIPT_DIR"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/pyproject.toml" ]]; then
      REPO_ROOT="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi

if [[ -z "${REPO_ROOT:-}" || ! -f "${REPO_ROOT}/pyproject.toml" ]]; then
  error "Could not locate repository root (pyproject.toml not found)"
  exit 2
fi

info "repo root: ${REPO_ROOT}"

# ── Per-run temp directory ─────────────────────────────────────────────────
# mktemp -d uses atomic mkdir (owner-only) semantics; trap guarantees cleanup.
SMOKE_DIR="$(mktemp -d -t pup_py_smoke.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/pup_py_smoke.XXXXXX")"
trap 'rm -rf -- "${SMOKE_DIR}"' EXIT INT TERM

DIST_DIR="${SMOKE_DIR}/dist"
VENV_DIR="${SMOKE_DIR}/venv"

info "per-run temp dir: ${SMOKE_DIR}"

# ── Prerequisite checks ───────────────────────────────────────────────────
USE_UV=false
if command -v uv >/dev/null 2>&1; then
  USE_UV=true
  info "using uv: $(uv --version 2>/dev/null || true)"
fi

if [[ "${USE_UV}" != "true" ]] && ! command -v pip >/dev/null 2>&1; then
  error "Neither uv nor pip found on PATH. Install one to proceed."
  exit 2
fi

# ── Build wheel ────────────────────────────────────────────────────────────
if [[ "${SKIP_BUILD}" == "true" ]]; then
  # Reuse existing dist dir (must have been created by a previous run
  # in the same SMOKE_DIR, which only happens within the same invocation
  # with --skip-build used for iterative debugging).  If nothing is
  # there, fall through to build.
  WHEEL_FILE="$(find "${DIST_DIR}" -maxdepth 1 -name '*.whl' -print -quit 2>/dev/null || true)"
  if [[ -n "${WHEEL_FILE}" ]]; then
    info "reusing existing wheel: ${WHEEL_FILE}"
  else
    warn "--skip-build requested but no wheel found; building fresh"
    SKIP_BUILD=false
  fi
fi

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "building wheel (uv build --out-dir ${DIST_DIR})..."
  mkdir -p "${DIST_DIR}"

  if [[ "${USE_UV}" == "true" ]]; then
    (cd "${REPO_ROOT}" && uv build --out-dir "${DIST_DIR}" --wheel)
  else
    (cd "${REPO_ROOT}" && pip wheel --no-deps --wheel-dir "${DIST_DIR}" .)
  fi

  WHEEL_FILE="$(find "${DIST_DIR}" -maxdepth 1 -name '*.whl' -print -quit 2>/dev/null || true)"
  if [[ -z "${WHEEL_FILE}" ]]; then
    error "no .whl file found in ${DIST_DIR} after build"
    exit 1
  fi
  ok "wheel built: $(basename "${WHEEL_FILE}")"
fi

# ── Create venv and install ────────────────────────────────────────────────
info "creating temporary venv at ${VENV_DIR}..."

if [[ "${USE_UV}" == "true" ]]; then
  uv venv "${VENV_DIR}" --no-project 2>/dev/null
  # uv pip install does not require activating the venv; pass --python
  info "installing wheel into venv..."
  uv pip install --python "${VENV_DIR}/bin/python" "${WHEEL_FILE}"
else
  python3 -m venv "${VENV_DIR}"
  info "installing wheel into venv..."
  "${VENV_DIR}/bin/pip" install "${WHEEL_FILE}"
fi

ok "wheel installed into temporary venv"

# ── Verify entry points ───────────────────────────────────────────────────
# Run --help on each installed entry point.  A non-zero exit or missing
# binary counts as a failure.  We do NOT test the gac entry point here
# because it requires a git repo context; code-puppy and pup are the
# primary CLI entry points.

PYTHON="${VENV_DIR}/bin/python"
FAILED=0

check_entry_point() {
  local name="$1"
  local bin_path="${VENV_DIR}/bin/${name}"

  if [[ ! -x "${bin_path}" ]]; then
    error "entry point binary not found: ${bin_path}"
    FAILED=1
    return
  fi

  info "checking: ${name} --help"
  set +e
  "${bin_path}" --help >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "${name} --help: OK"
  else
    error "${name} --help: FAILED (exit ${rc})"
    FAILED=1
  fi
}

check_module() {
  local module="$1"

  info "checking: python -m ${module} --help"
  set +e
  "${PYTHON}" -m "${module}" --help >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "python -m ${module} --help: OK"
  else
    error "python -m ${module} --help: FAILED (exit ${rc})"
    FAILED=1
  fi
}

check_entry_point "code-puppy"
check_entry_point "pup"
check_module "code_puppy"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  ok "Python package artifact smoke PASSED"
else
  error "Python package artifact smoke FAILED"
fi

exit ${FAILED}
