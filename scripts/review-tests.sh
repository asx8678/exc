#!/usr/bin/env bash
#
# Automated Code Review for Test Files
#
# Invokes elixir-reviewer (for .exs) and
# qa-expert agents on test files, producing pass/fail results.
#
# Usage:
#   ./scripts/review-tests.sh <file_or_dir> [file_or_dir ...]
#   ./scripts/review-tests.sh elixir/code_puppy_control/test/llm/
#   ./scripts/review-tests.sh elixir/code_puppy_control/test/bar_test.exs
#
# Exit codes:
#   0 - All reviews passed (or only advisory findings)
#   1 - Blocking issues found
#   2 - Usage error / no files to review
#
# Environment:
#   REVIEW_BLOCKING - Set to "1" to treat all findings as blocking (default: advisory)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Config ───────────────────────────────────────────────────────────
BLOCKING="${REVIEW_BLOCKING:-0}"
BLOCKING_ISSUES=0
ADVISORY_ISSUES=0
TOTAL_FILES=0
RESULTS_DIR=""

# ─── Helpers ──────────────────────────────────────────────────────────
usage() {
  cat <<HELP
${BOLD}Automated Code Review for Test Files${RESET}

Usage:
  $(basename "$0") <file_or_dir> [file_or_dir ...]

Options:
  --blocking    Treat all findings as blocking (overrides REVIEW_BLOCKING)
  --help        Show this help

Examples:
  $(basename "$0") elixir/code_puppy_control/test/llm/
  $(basename "$0") elixir/code_puppy_control/test/bar_test.exs

Environment:
  REVIEW_BLOCKING=1   Treat findings as blocking (default: advisory)
HELP
}

log()  { echo -e "${CYAN}[review]${RESET} $*"; }
pass() { echo -e "  ${GREEN}✓ PASS${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠ ADVISORY${RESET} $*" >&2; ((ADVISORY_ISSUES++)); }
fail() { echo -e "  ${RED}✗ BLOCKING${RESET} $*" >&2; ((BLOCKING_ISSUES++)); }

# Determine the appropriate reviewer agent for a file
reviewer_for() {
  local file="$1"
  case "$file" in
    *_test.exs|*.exs)  echo "elixir-reviewer" ;;
    *)                  echo "none" ;;
  esac
}

# Collect test files from arguments (files or directories)
collect_files() {
  local -a files=()
  for target in "$@"; do
    if [[ -f "$target" ]]; then
      files+=("$target")
    elif [[ -d "$target" ]]; then
      # Find test files in directory
      while IFS= read -r -d '' f; do
        files+=("$f")
      done < <(find "$target" -type f -name "*_test.exs" -print0 2>/dev/null)
    else
      warn "Path not found, skipping: $target"
    fi
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${files[@]}" | sort -u
}

# ─── Parse Args ────────────────────────────────────────────────────────
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --blocking)  BLOCKING=1 ;;
    --help|-h)   usage; exit 0 ;;
    -*)          echo "Unknown flag: $arg"; usage; exit 2 ;;
    *)           TARGETS+=("$arg") ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No files or directories specified${RESET}"
  usage
  exit 2
fi

# ─── Collect Files ─────────────────────────────────────────────────────
log "Collecting test files..."
FILE_LIST=$(collect_files "${TARGETS[@]}")

# Trim whitespace and check if truly empty
FILE_LIST=$(echo "$FILE_LIST" | grep -v '^$' || true)

if [[ -z "$FILE_LIST" ]]; then
  log "No test files found in specified paths"
  exit 0
fi

TOTAL_FILES=$(echo "$FILE_LIST" | wc -l | tr -d ' ')
log "Found ${BOLD}${TOTAL_FILES}${RESET} test file(s) to review"

# Create temp dir for results
RESULTS_DIR=$(mktemp -d /tmp/code-puppy-review.XXXXXX)
trap 'rm -rf "$RESULTS_DIR"' EXIT

# ─── Phase 1: Language-Specific Review ─────────────────────────────────
echo ""
log "${BOLD}Phase 1: Language-specific review${RESET}"

# Group files by reviewer (using temp files — macOS bash lacks declare -A)
while IFS= read -r file; do
  reviewer=$(reviewer_for "$file")
  if [[ "$reviewer" != "none" ]]; then
    echo "$file" >> "${RESULTS_DIR}/${reviewer}.list"
  else
    warn "No reviewer agent for: $file (unsupported extension)"
  fi
done <<< "$FILE_LIST"

# Process each reviewer that has files
for list_file in "${RESULTS_DIR}"/*.list; do
  [[ ! -f "$list_file" ]] && continue
  reviewer=$(basename "$list_file" .list)
  file_count=$(grep -c . "$list_file")
  log "Running ${BOLD}${reviewer}${RESET} on ${file_count} file(s)..."

  result_file="${RESULTS_DIR}/${reviewer}.md"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    log "  Reviewing: $file"

    # Build review prompt
    prompt="Review the test file: ${file}

Focus on:
- Test structure and naming conventions
- Assertion quality (testing behavior, not implementation)
- Edge cases and error path coverage
- Anti-patterns (flaky tests, hardcoded values, test interdependence)
- Idiomatic patterns for the language/framework

Provide a summary with:
- PASS: No issues found
- ADVISORY: Minor issues (style, naming, minor gaps)
- BLOCKING: Critical issues (anti-patterns, missing assertions, flaky patterns)"

    # Invoke the agent via code-puppy CLI if available, otherwise echo instructions
    if command -v code-puppy >/dev/null 2>&1; then
      code-puppy --agent "$reviewer" --prompt "$prompt" >> "$result_file" 2>&1 || true
    else
      echo "[manual review required] Run: code-puppy --agent $reviewer --prompt \"$prompt\"" >> "$result_file"
    fi
  done < "$list_file"

  # Parse results
  if [[ -f "$result_file" ]]; then
    # Quick heuristic scan for blocking keywords in output
    if grep -qiE 'blocking|critical|anti-pattern|flaky|broken' "$result_file" 2>/dev/null; then
      if [[ "$BLOCKING" == "1" ]]; then
        fail "${reviewer} found blocking issues (see ${result_file})"
      else
        warn "${reviewer} found issues (advisory) (see ${result_file})"
      fi
    else
      pass "${reviewer} review complete"
    fi
  fi
done

# ─── Phase 2: QA Coverage Analysis ─────────────────────────────────────
echo ""
log "${BOLD}Phase 2: QA coverage analysis${RESET}"

qa_result="${RESULTS_DIR}/qa-expert.md"
qa_prompt="Analyze test coverage and quality for the following test files:

${FILE_LIST}

Focus on:
- Coverage gaps: Are important behaviors untested?
- Assertion quality: Do tests verify the right things?
- Test isolation: Can tests run independently?
- Test pyramid: Is the balance of unit/integration/e2e correct?
- Risk assessment: What's the risk level of gaps found?

Provide a summary with:
- PASS: Adequate coverage
- ADVISORY: Minor gaps (nice-to-have coverage)
- BLOCKING: Critical gaps (untested error paths, missing edge cases)"

log "Running ${BOLD}qa-expert${RESET} on ${TOTAL_FILES} file(s)..."

if command -v code-puppy >/dev/null 2>&1; then
  code-puppy --agent "qa-expert" --prompt "$qa_prompt" > "$qa_result" 2>&1 || true
else
  echo "[manual review required] Run: code-puppy --agent qa-expert --prompt \"\$qa_prompt\"" > "$qa_result"
fi

if [[ -f "$qa_result" ]]; then
  if grep -qiE 'blocking|critical|gap|missing.*coverage|untested' "$qa_result" 2>/dev/null; then
    if [[ "$BLOCKING" == "1" ]]; then
      fail "qa-expert found blocking coverage issues (see ${qa_result})"
    else
      warn "qa-expert found coverage gaps (advisory) (see ${qa_result})"
    fi
  else
    pass "qa-expert coverage analysis complete"
  fi
fi

# ─── Summary ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Code Review Summary${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "  Files reviewed:   ${TOTAL_FILES}"
echo -e "  Blocking issues:  ${RED}${BLOCKING_ISSUES}${RESET}"
echo -e "  Advisory issues:  ${YELLOW}${ADVISORY_ISSUES}${RESET}"
echo ""
echo -e "  Detailed results:  ${RESULTS_DIR}/"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

# ─── Exit Code ─────────────────────────────────────────────────────────
if [[ "$BLOCKING" == "1" && "$BLOCKING_ISSUES" -gt 0 ]]; then
  echo -e "\n${RED}Blocking issues found. Fix before merging.${RESET}"
  exit 1
elif [[ "$BLOCKING_ISSUES" -gt 0 ]]; then
  echo -e "\n${YELLOW}Issues found (advisory mode). Review recommended.${RESET}"
  exit 0
else
  echo -e "\n${GREEN}All reviews passed! 🐶${RESET}"
  exit 0
fi
