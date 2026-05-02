#!/usr/bin/env bash
#
# Code Puppy Dev Launcher
#
# Starts the Code Puppy API server with graceful shutdown via trap cleanup.
#
# Usage:
#   ./scripts/run_dev.sh
#   ./scripts/run_dev.sh --help
#
# Environment:
#   PUPPY_API_PORT - API port (default: 8765)
#   PUPPY_API_HOST - bind host (default: 127.0.0.1)
#

set -euo pipefail

# Assume we're in repo root or scripts/ subdir
cd -P . 2>/dev/null || true

# ----- CLI -----
show_help() {
  cat <<HELP
Code Puppy dev launcher.

Usage:
  ./scripts/run_dev.sh           Launch dev services
  ./scripts/run_dev.sh --help    Show this help

Environment:
  PUPPY_API_PORT   API port (default: 8765)
  PUPPY_API_HOST   Bind host (default: 127.0.0.1)
HELP
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_help
  exit 0
fi

# ----- Config -----
API_PORT="${PUPPY_API_PORT:-8765}"
API_HOST="${PUPPY_API_HOST:-127.0.0.1}"

# ----- Cleanup -----
API_PID=""

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "$API_PID" ]] && kill -0 "$API_PID" 2>/dev/null; then
    echo ""
    echo "==> Stopping API server (pid $API_PID)..."
    kill "$API_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      if ! kill -0 "$API_PID" 2>/dev/null; then break; fi
      sleep 0.2
    done
    if kill -0 "$API_PID" 2>/dev/null; then
      kill -9 "$API_PID" 2>/dev/null || true
    fi
    wait "$API_PID" 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT INT TERM

# ----- Launch -----
echo "==> Code Puppy dev launcher"
echo "==> API: $API_HOST:$API_PORT"
echo ""

if ! command -v uv >/dev/null 2>&1; then
  echo "==> ERROR: uv not installed"
  exit 1
fi

echo "==> code-puppy CLI is available"
echo ""
echo "==> NOTE: API dev mode not yet implemented (issue code_puppy-ac5)"

# Real launch would go here
exit 0
