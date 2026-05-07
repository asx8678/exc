#!/usr/bin/env bash
# no-python-files-guard.sh — prevent reintroduction of legacy Python product files
#
# Fails if any tracked files match legacy Python product/runtime patterns
# that were removed in epic E (code-puppy-3o7.8). This guard ensures the
# native-only CI gate holds (code-puppy-3o7.5.4).
#
# Checks:
#   1. No tracked *.py files (except allowlisted parser/data files)
#   2. No tracked Python packaging files: pyproject.toml, uv.lock, .python-version
#   3. No tracked code_puppy/ directory (root Python package)
#   4. No tracked root tests/ directory (Python test suite)
#
# ADR-005 Python-as-data: .ex/.xrl/.yrl parser files (python_lexer.ex,
# python_parser.ex, python_lexer.xrl, python_parser.yrl) are allowlisted.
# No .py files are allowlisted — the native runtime has no Python source.
#
# Exit codes:
#   0  guard passed — no forbidden files found
#   1  guard failed — forbidden files detected
#
# Refs: code-puppy-3o7.5.4

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
FAILED=0

info()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ── Locate repo root ───────────────────────────────────────────────────────
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "${REPO_ROOT}" ]]; then
  error "could not locate git repository root"
  exit 1
fi

cd "${REPO_ROOT}"

# ── Check 1: No tracked *.py files ─────────────────────────────────────────
PY_FILES="$(git ls-files '*.py' 2>/dev/null || true)"

if [[ -n "${PY_FILES}" ]]; then
  error "tracked .py files found (legacy Python product deleted in code-puppy-3o7.8):"
  while IFS= read -r f; do
    error "  ${f}"
  done <<< "${PY_FILES}"
  FAILED=1
else
  info "no tracked .py files — OK"
fi

# ── Check 2: No Python packaging files ──────────────────────────────────────
PACKAGING_FILES=()
for f in pyproject.toml uv.lock .python-version; do
  if git ls-files -- "$f" 2>/dev/null | grep -q .; then
    PACKAGING_FILES+=("$f")
  fi
done

if [[ ${#PACKAGING_FILES[@]} -gt 0 ]]; then
  error "tracked Python packaging files found:"
  for f in "${PACKAGING_FILES[@]}"; do
    error "  ${f}"
  done
  FAILED=1
else
  info "no tracked Python packaging files (pyproject.toml, uv.lock, .python-version) — OK"
fi

# ── Check 3: No root code_puppy/ directory ─────────────────────────────────
if git ls-files -- 'code_puppy/' 2>/dev/null | grep -q .; then
  error "tracked files under code_puppy/ found (root Python package deleted in code-puppy-3o7.8):"
  git ls-files -- 'code_puppy/' 2>/dev/null | head -5 | while IFS= read -r f; do
    error "  ${f}"
  done
  COUNT="$(git ls-files -- 'code_puppy/' 2>/dev/null | wc -l | tr -d ' ')"
  error "  ... (${COUNT} total files)"
  FAILED=1
else
  info "no tracked code_puppy/ directory — OK"
fi

# ── Check 4: No root tests/ directory (Python test suite) ─────────────────
if git ls-files -- 'tests/' 2>/dev/null | grep -q .; then
  error "tracked files under tests/ found (root Python test suite deleted in code-puppy-3o7.8):"
  git ls-files -- 'tests/' 2>/dev/null | head -5 | while IFS= read -r f; do
    error "  ${f}"
  done
  COUNT="$(git ls-files -- 'tests/' 2>/dev/null | wc -l | tr -d ' ')"
  error "  ... (${COUNT} total files)"
  FAILED=1
else
  info "no tracked tests/ directory — OK"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
if [[ "${FAILED}" -eq 0 ]]; then
  info "GUARD PASSED — no legacy Python product files detected"
else
  error "GUARD FAILED — legacy Python product files detected; remove them or update allowlist"
fi

exit ${FAILED}
