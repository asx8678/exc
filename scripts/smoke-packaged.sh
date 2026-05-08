#!/usr/bin/env bash
# scripts/smoke-packaged.sh — packaged-CLI smoke wrapper
#
# Builds the shipped CLI artifact(s) and runs the no-network dogfood
# smoke runner against them.  Designed to be deterministic and
# CI-friendly: never touches `~/.code_puppy_ex/`, never makes network
# calls, never asks for API keys.
#
# Layers (each layer is opt-in past the default escript layer):
#
#   1. (default)         escript-only smoke
#                        -> `mix escript.build` + `mix pup_ex.smoke --escript`
#
#   2. --with-burrito    add a host-only Burrito build + Burrito smoke
#                        -> `scripts/build-burrito.sh --host-only` +
#                          `mix pup_ex.smoke --escript --burrito`
#                        Requires Zig on PATH **AND** a Burrito-
#                        compatible Zig version (0.13.x – 0.15.x for
#                        Burrito 1.3 – 1.5).  Without a compatible Zig,
#                        prints a clear skip notice and exits 0 (this
#                        is the documented opt-in behaviour for
#                        code_puppy-d7m).
#
#   3. --strict          do NOT skip on missing or incompatible
#                        toolchain; exit non-zero if Zig is requested
#                        but missing or unusable.  Useful for CI
#                        images that should always have a known-good
#                        Zig pre-installed.
#
#   4. --no-python        validate the Python-free runtime guarantee:
#                        run packaged CLI smoke with a sanitized PATH
#                        that excludes python3/python.  Proves the
#                        packaged CLI starts and shows help/version
#                        without Python installed.
#
# Usage:
#   scripts/smoke-packaged.sh                       # escript-only smoke
#   scripts/smoke-packaged.sh --json                # JSON report
#   scripts/smoke-packaged.sh --with-burrito        # add Burrito layer
#   scripts/smoke-packaged.sh --with-burrito --strict
#   scripts/smoke-packaged.sh --skip-build          # reuse an already-built ./pup
#   scripts/smoke-packaged.sh --no-python           # validate no-Python runtime
#   scripts/smoke-packaged.sh --no-python --with-burrito
#
# Exit codes:
#   0  every selected layer passed (or was deliberately skipped)
#   1  at least one layer failed
#   2  bad arguments
#
# Refs: code_puppy-d7m

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[smoke-packaged]${NC} $*"; }
ok()    { echo -e "${GREEN}[smoke-packaged]${NC} $*"; }
warn()  { echo -e "${YELLOW}[smoke-packaged]${NC} $*"; }
error() { echo -e "${RED}[smoke-packaged]${NC} $*" >&2; }

# Determine whether the Zig version on PATH is compatible with the
# Burrito version pinned in mix.lock.  Burrito 1.3 – 1.5 supports the
# Zig 0.13.x – 0.15.x line; 0.16+ ships breaking changes Burrito has
# not adopted yet, and every 0.x.y bump in Zig has historically broken
# at least one Burrito codepath, so we hard-pin the major.minor here.
#
# Echoes (to stdout, single line):
#   compatible:<version>          — Zig is usable for the Burrito build
#   incompatible:<version>:<why>  — Zig is on PATH but unusable
#   missing                       — Zig is not on PATH
#
# Exit code is always 0; callers branch on the prefix.  This keeps
# the function deterministic and trivially shimmable in tests via a
# fake `zig` on PATH.
#
# Refs: code_puppy-d7m
zig_compat_status() {
  if ! command -v zig >/dev/null 2>&1; then
    echo "missing"
    return 0
  fi

  local zver
  zver="$(zig version 2>/dev/null || true)"

  if [[ -z "${zver}" ]]; then
    echo "incompatible::zig on PATH but \`zig version\` produced no output"
    return 0
  fi

  case "${zver}" in
    0.13.*|0.14.*|0.15.*)
      echo "compatible:${zver}"
      ;;
    *)
      echo "incompatible:${zver}:Zig ${zver} is outside the Burrito-supported range (0.13.x – 0.15.x); Burrito 1.3–1.5 has not adopted later Zig releases"
      ;;
  esac
}

# ── Parse arguments ───────────────────────────────────────────────────────
WITH_BURRITO=false
STRICT=false
SKIP_BUILD=false
NO_PYTHON=false
JSON_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-burrito) WITH_BURRITO=true; shift ;;
    --strict)        STRICT=true; shift ;;
    --skip-build)    SKIP_BUILD=true; shift ;;
    --no-python)     NO_PYTHON=true; shift ;;
    --json)          JSON_FLAG="--json"; shift ;;
    --help|-h)
      sed -n '1,50p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 2
      ;;
  esac
done

# ── Locate the Elixir project ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "${PROJECT_ROOT}/mix.exs" ]]; then
  error "could not find mix.exs at ${PROJECT_ROOT}"
  exit 2
fi

cd "${PROJECT_ROOT}"
info "project root: ${PROJECT_ROOT}"

# ── Per-run log directory (refs: code_puppy-d7m) ───────────────────────────
# Build logs land in a private mktemp dir, NEVER fixed `/tmp/pup_*.log`
# paths.  The previous behaviour was clobber-prone (two concurrent CI
# runs racing on the same path) and exposed a symlink-attack surface
# (a pre-existing /tmp/pup_escript_build.log symlinked to /etc/passwd
# would have been silently truncated by `>` redirection).  `mktemp -d`
# uses `mkdir` semantics (atomic, owner-only by default) and the trap
# guarantees cleanup even on Ctrl-C / unexpected exit.
LOG_DIR="$(mktemp -d -t pup_smoke.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/pup_smoke.XXXXXX")"
trap 'rm -rf -- "${LOG_DIR}"' EXIT INT TERM
ESCRIPT_BUILD_LOG="${LOG_DIR}/escript_build.log"
BURRITO_BUILD_LOG="${LOG_DIR}/burrito_build.log"
info "per-run log dir: ${LOG_DIR}"

# ── Prerequisite checks ───────────────────────────────────────────────
if ! command -v mix >/dev/null 2>&1; then
  error "Elixir/Mix not found on PATH. Install Elixir first."
  exit 1
fi

# ── Layer 1: escript build + smoke ───────────────────────────────────────
ESCRIPT_PATH="${PROJECT_ROOT}/pup"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "building escript (mix escript.build)..."
  mix escript.build >"${ESCRIPT_BUILD_LOG}" 2>&1 || {
    error "mix escript.build failed; see ${ESCRIPT_BUILD_LOG}"
    tail -40 "${ESCRIPT_BUILD_LOG}" >&2 || true
    exit 1
  }
  ok "escript built: ${ESCRIPT_PATH}"
else
  if [[ ! -x "${ESCRIPT_PATH}" ]]; then
    error "--skip-build requested but ${ESCRIPT_PATH} does not exist"
    exit 1
  fi
  info "reusing existing escript: ${ESCRIPT_PATH}"
fi

# ── Layer 2 (optional): Burrito host-only build ──────────────────────────
BURRITO_FLAG=""

if [[ "${WITH_BURRITO}" == "true" ]]; then
  ZIG_STATUS="$(zig_compat_status)"

  case "${ZIG_STATUS}" in
    compatible:*)
      ZIG_VERSION="${ZIG_STATUS#compatible:}"
      info "Zig ${ZIG_VERSION} detected (Burrito-compatible); building host-only Burrito..."

      if [[ ! -x "${SCRIPT_DIR}/build-burrito.sh" ]]; then
        error "scripts/build-burrito.sh missing or not executable"
        exit 1
      fi

      "${SCRIPT_DIR}/build-burrito.sh" --host-only >"${BURRITO_BUILD_LOG}" 2>&1 || {
        error "Burrito host-only build failed; see ${BURRITO_BUILD_LOG}"
        tail -40 "${BURRITO_BUILD_LOG}" >&2 || true
        exit 1
      }
      ok "Burrito host-only build complete"
      BURRITO_FLAG="--burrito"
      ;;

    incompatible:*)
      # Format: incompatible:<version>:<reason>
      ZIG_REST="${ZIG_STATUS#incompatible:}"
      ZIG_VERSION="${ZIG_REST%%:*}"
      ZIG_REASON="${ZIG_REST#*:}"

      if [[ "${STRICT}" == "true" ]]; then
        error "--with-burrito --strict requested but Zig is incompatible: ${ZIG_REASON}"
        error "Install a Burrito-compatible Zig (0.13.x – 0.15.x)"
        exit 1
      else
        warn "Zig ${ZIG_VERSION} on PATH is incompatible with Burrito -- skipping Burrito layer (use --strict to fail)"
        warn "reason: ${ZIG_REASON}"
        warn "install a Burrito-compatible Zig (0.13.x – 0.15.x) and re-run with --with-burrito to exercise this layer"
      fi
      ;;

    missing)
      if [[ "${STRICT}" == "true" ]]; then
        error "--with-burrito --strict requested but Zig is not on PATH"
        error "Install Zig (brew install zig / apt install zig / choco install zig)"
        exit 1
      else
        warn "Zig not on PATH -- skipping Burrito layer (use --strict to fail)"
        warn "Install Zig and re-run with --with-burrito to exercise this layer"
      fi
      ;;

    *)
      # Defensive: should never happen unless zig_compat_status grows a
      # new return prefix without updating this case statement.
      error "internal error: zig_compat_status returned unexpected value: ${ZIG_STATUS}"
      exit 1
      ;;
  esac
fi

NO_PYTHON_FLAG=""
if [[ "${NO_PYTHON}" == "true" ]]; then
  NO_PYTHON_FLAG="--no-python"
fi

# ── Run the smoke ─────────────────────────────────────────────────────────
info "running mix pup_ex.smoke --escript ${BURRITO_FLAG} ${NO_PYTHON_FLAG} ${JSON_FLAG}"
SMOKE_ARGS=("pup_ex.smoke" "--escript")
if [[ -n "${BURRITO_FLAG}" ]]; then
  SMOKE_ARGS+=("${BURRITO_FLAG}")
fi
if [[ -n "${NO_PYTHON_FLAG}" ]]; then
  SMOKE_ARGS+=("${NO_PYTHON_FLAG}")
fi
if [[ -n "${JSON_FLAG}" ]]; then
  SMOKE_ARGS+=("${JSON_FLAG}")
fi

set +e
mix "${SMOKE_ARGS[@]}"
SMOKE_EXIT=$?
set -e

if [[ ${SMOKE_EXIT} -eq 0 ]]; then
  ok "packaged-CLI smoke PASS"
else
  error "packaged-CLI smoke FAIL (exit ${SMOKE_EXIT})"
fi

exit ${SMOKE_EXIT}
