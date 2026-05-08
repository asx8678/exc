#!/usr/bin/env bash
# scripts/build-burrito.sh - Build a Burrito single-binary release
#
# Prerequisites:
#   - Zig compiler on PATH (brew install zig / apt install zig / choco install zig)
#   - MIX_ENV=prod will be set automatically
#
# Usage:
#   scripts/build-burrito.sh                # build all targets
#   scripts/build-burrito.sh --host-only     # build only for current platform
#   scripts/build-burrito.sh --target macos_arm64  # build specific target

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[burrito]${NC} $*"; }
warn()  { echo -e "${YELLOW}[burrito]${NC} $*"; }
error() { echo -e "${RED}[burrito]${NC} $*" >&2; }

# ── Prerequisite checks ───────────────────────────────────────────────────

if ! command -v zig >/dev/null 2>&1; then
  error "Zig compiler not found on PATH."
  echo ""
  echo "Install Zig:"
  echo "  macOS:   brew install zig"
  echo "  Ubuntu:  apt install zig   (ensure version >= 0.11)"
  echo "  Windows: choco install zig"
  echo ""
  echo "See https://ziglang.org/learn/getting-started/ for alternative methods."
  exit 1
fi

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
info "Zig version: ${ZIG_VERSION}"

if ! command -v mix >/dev/null 2>&1; then
  error "Elixir/Mix not found on PATH. Install Elixir first."
  exit 1
fi

info "Elixir version: $(elixir --version 2>/dev/null | tail -1)"

# ── Parse arguments ───────────────────────────────────────────────────────

HOST_ONLY=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-only)
      HOST_ONLY=true
      shift
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        error "--target requires an argument (e.g. macos_arm64)"
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--host-only|--target <target>]"
      echo ""
      echo "Targets: macos_arm64, macos_x86_64, linux_x86_64, linux_arm64,"
      echo "         linux_musl_x86_64, linux_musl_arm64, windows_x86_64"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ── Build ──────────────────────────────────────────────────────────────────

export MIX_ENV=prod

# Set BURRITO_TARGET if a specific target or host-only is requested
if [[ -n "${TARGET}" ]]; then
  export BURRITO_TARGET="${TARGET}"
  info "Building single target: ${TARGET}"
elif [[ "${HOST_ONLY}" == "true" ]]; then
  # Detect the current platform and map to Burrito target name
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "${OS}" in
    Darwin)
      if [[ "${ARCH}" == "arm64" ]]; then
        export BURRITO_TARGET="macos_arm64"
      else
        export BURRITO_TARGET="macos_x86_64"
      fi
      ;;
    Linux)
      # Detect musl vs glibc by checking the dynamic linker
      IS_MUSL=false
      if [[ -f /etc/alpine-release ]] || ldd --version 2>&1 | grep -qi musl; then
        IS_MUSL=true
      fi
      if [[ "${ARCH}" == "aarch64" ]]; then
        if [[ "${IS_MUSL}" == "true" ]]; then
          export BURRITO_TARGET="linux_musl_arm64"
        else
          export BURRITO_TARGET="linux_arm64"
        fi
      else
        if [[ "${IS_MUSL}" == "true" ]]; then
          export BURRITO_TARGET="linux_musl_x86_64"
        else
          export BURRITO_TARGET="linux_x86_64"
        fi
      fi
      ;;
    *)
      warn "Unsupported host OS: ${OS}. Building all targets instead."
      ;;
  esac

  if [[ -n "${BURRITO_TARGET:-}" ]]; then
    info "Host-only build: ${BURRITO_TARGET} (detected ${OS}/${ARCH})"
  fi
fi

# Ensure dependencies are fetched and compiled for prod
info "Fetching dependencies (MIX_ENV=prod)..."
mix deps.get --only prod

info "Compiling dependencies..."
mix deps.compile

info "Compiling application..."
mix compile

info "Building Burrito release..."
mix release code_puppy_control --overwrite

# ── Report results ─────────────────────────────────────────────────────────

OUTPUT_DIR="burrito_out"

if [[ -d "${OUTPUT_DIR}" ]]; then
  info "Build complete! Output binaries:"
  ls -lh "${OUTPUT_DIR}/" 2>/dev/null | tail -n +2 | while read -r line; do
    echo "  ${line}"
  done
else
  warn "Expected output directory '${OUTPUT_DIR}/' not found. Check build output above for errors."
fi
