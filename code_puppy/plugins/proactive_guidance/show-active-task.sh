#!/bin/bash
# show-active-task.sh - Display AgentSpawn context and active task information
# Usage: show-active-task.sh [options]
#
# This script displays information about the currently active task context,
# including agent hierarchy, task goals, and related state. Useful for
# understanding what Code Puppy is currently working on.
#
# Options:
#   -h, --help       Show this help message
#   -j, --json       Output as JSON (for programmatic use)
#   -v, --verbose    Show detailed information
#   --tree           Show agent hierarchy as a tree
#
# Examples:
#   show-active-task.sh              # Display basic active task info
#   show-active-task.sh --verbose    # Show detailed info
#   show-active-task.sh --json       # Output JSON for scripts

set -euo pipefail

# Escape a string for safe embedding in a JSON double-quoted value.
# Handles backslash, double-quote, and common control characters.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash  → \\
    s="${s//\"/\\\"}"   # double-quote → \"
    s="${s//$'\t'/\\t}"  # tab → \t
    s="${s//$'\n'/\\n}"  # newline → \n
    s="${s//$'\r'/\\r}"  # carriage-return → \r
    printf '%s' "$s"
}


# Normalize an env value to a strict JSON boolean (true / false).
# Accepts: true/false, 1/0, yes/no, on/off (case-insensitive).
# Anything else defaults to the given fallback (default: true).
normalize_bool() {
    local raw="${1:-}"
    local fallback="${2:-true}"
    local lower
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        true|1|yes|on)  echo "true"  ;;
        false|0|no|off) echo "false" ;;
        "")             echo "$fallback" ;;
        *)              echo "$fallback" ;;
    esac
}

# Normalize an env value to a safe integer.
# Accepts ONLY strings composed entirely of digits (0-9), optionally with
# leading zeros.  Anything else (including negatives, ranges, or mixed
# alphanumeric) falls back to the given default (default: 0).
normalize_int() {
    local raw="${1:-}"
    local fallback="${2:-0}"
    # Reject anything that is not purely digits
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
        echo "$fallback"
        return
    fi
    # Strip leading zeros so we don't emit octal-looking values
    local cleaned
    cleaned="${raw#"${raw%%[!0]*}"}"
    [[ -z "$cleaned" ]] && cleaned=0
    echo "$cleaned"
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FORMAT="text"
VERBOSE=false
SHOW_TREE=false

# Colors
if [[ -z "${NO_COLOR:-}" ]]; then
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    GRAY='\033[0;90m'
    RESET='\033[0m'
else
    BOLD=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    GRAY=''
    RESET=''
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Display AgentSpawn context and active task information"
            echo ""
            echo "Options:"
            echo "  -h, --help       Show this help message"
            echo "  -j, --json       Output as JSON"
            echo "  -v, --verbose    Show detailed information"
            echo "  --tree           Show agent hierarchy as tree"
            echo ""
            echo "Environment:"
            echo "  NO_COLOR=1       Disable colors"
            echo "  PUP_TASK_ID      Override task ID detection"
            exit 0
            ;;
        -j|--json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --tree)
            SHOW_TREE=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage" >&2
            exit 1
            ;;
    esac
done

# Get environment info
get_env_info() {
    cat <<EOF
{
    "cwd": "$(json_escape "$(pwd)")",
    "home": "$(json_escape "${HOME:-unknown}")",
    "shell": "$(json_escape "${SHELL:-unknown}")",
    "term": "$(json_escape "${TERM:-unknown}")",
    "user": "$(json_escape "${USER:-unknown}")",
    "pup_task_id": "$(json_escape "${PUP_TASK_ID:-${PUPPY_TASK_ID:-auto-detected}}")"
}
EOF
}

# Get git info
get_git_info() {
    local git_info="{}"
    
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git_info=$(cat <<EOF
{
    "branch": "$(json_escape "$(git branch --show-current 2>/dev/null || echo 'unknown')")",
    "commit": "$(json_escape "$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')")",
    "dirty": $(git diff --quiet 2>/dev/null && echo "false" || echo "true"),
    "remote_url": "$(json_escape "$(git remote get-url origin 2>/dev/null || echo 'none')")"
}
EOF
)
    fi
    
    echo "$git_info"
}

# Shared project-type detector (single source of truth for JSON and text).
# Returns two variables: _proj_type (machine key) and _proj_display (human label).
detect_project_type() {
    if [[ -f "pyproject.toml" ]]; then
        _proj_type="python"
        _proj_display="Python"
    elif [[ -f "package.json" ]]; then
        _proj_type="nodejs"
        _proj_display="Node.js"
    elif [[ -f "Cargo.toml" ]]; then
        _proj_type="rust"
        _proj_display="Rust"
    elif [[ -f "go.mod" ]]; then
        _proj_type="go"
        _proj_display="Go"
    elif [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then
        _proj_type="java"
        _proj_display="Java"
    elif [[ -f "Makefile" ]] || [[ -f "CMakeLists.txt" ]]; then
        _proj_type="c/c++"
        _proj_display="C/C++"
    else
        _proj_type="unknown"
        _proj_display="unknown"
    fi
}

# Get project info (JSON)
get_project_info() {
    detect_project_type
    local project_files="[]"
    case "$_proj_type" in
        python)   project_files='["pyproject.toml", "requirements.txt"]' ;;
        nodejs)   project_files='["package.json", "package-lock.json", "node_modules/"]' ;;
        rust)     project_files='["Cargo.toml", "Cargo.lock", "target/"]' ;;
        go)       project_files='["go.mod", "go.sum"]' ;;
        java)     project_files='["pom.xml", "build.gradle"]' ;;
        c/c++)    project_files='["Makefile", "CMakeLists.txt"]' ;;
    esac
    cat <<EOF
{
    "type": "$_proj_type",
    "key_files": $project_files
}
EOF
}

# Build agent hierarchy tree
# In real implementation, this would read from Code Puppy's state
build_agent_tree() {
    local depth="${1:-0}"
    local prefix=""
    
    for ((i=0; i<depth; i++)); do
        prefix="$prefix  "
    done
    
    if [[ "$SHOW_TREE" == true ]]; then
        echo -e "${BOLD}Agent Hierarchy:${RESET}"
        echo ""
        echo -e "${CYAN}🐕 code-puppy${RESET} (root agent)"
        echo -e "  ${MAGENTA}🤖 turbo-executor${RESET} (active, Phase 3)"
        echo -e "    ${MAGENTA}🤖 file_service${RESET} (file ops)"
        echo -e "    ${MAGENTA}🤖 parse_agent${RESET} (tree-sitter)"
        echo -e "  ${MAGENTA}🤖 proactive-guidance${RESET} (this plugin)"
        echo ""
    fi
}

# Get active tasks info from real context sources
get_active_tasks() {
    # Detect task ID from env or git branch heuristic
    local task_id="${PUP_TASK_ID:-${PUPPY_TASK_ID:-}}"

    local task_name="unknown"
    local task_status="unknown"
    if [[ -n "$task_id" ]]; then
        task_name="Task $task_id"
        task_status="active"
    fi

    local task_source="env"

    cat <<EOF
{
    "current_task": {
        "id": "$(json_escape "${task_id:-none}")",
        "name": "$(json_escape "$task_name")",
        "status": "$(json_escape "$task_status")"
    },
    "source": "$(json_escape "$task_source")"
}
EOF
}

# JSON output
output_json() {
    cat <<EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "environment": $(get_env_info),
    "git": $(get_git_info),
    "project": $(get_project_info),
    "tasks": $(get_active_tasks),
    "plugin": {
        "name": "proactive_guidance",
        "guidance_count": $(normalize_int "${PUP_GUIDANCE_COUNT:-${PUPPY_GUIDANCE_COUNT:-0}}" 0),
        "enabled": $(normalize_bool "${PUP_GUIDANCE_ENABLED:-${PUPPY_GUIDANCE_ENABLED:-true}}" true)
    }
}
EOF
}

# Text output
output_text() {
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}        🐾 CODE PUPPY - ACTIVE TASK CONTEXT         ${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo ""
    
    # Current Task
    echo -e "${BOLD}${CYAN}📋 Current Task:${RESET}"
    # Detect task ID from env
    _task_id="${PUP_TASK_ID:-${PUPPY_TASK_ID:-}}"
    echo -e "   ID: ${_task_id:-none detected}"
    if [[ -n "$_task_id" ]]; then
        echo -e "   Name: Task $_task_id"
    fi
    echo -e "   Branch: ${GREEN}$(git branch --show-current 2>/dev/null || echo 'unknown')${RESET}"
    echo ""
    
    # Environment
    echo -e "${BOLD}${YELLOW}💻 Environment:${RESET}"
    echo -e "   CWD: $(pwd)"
    echo -e "   User: ${USER:-unknown}"
    echo -e "   Shell: ${SHELL:-unknown}"
    
    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo -e "   Git Branch: ${CYAN}$(git branch --show-current 2>/dev/null || echo 'unknown')${RESET}"
        echo -e "   Commit: ${GRAY}$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')${RESET}"
    fi
    echo ""
    
    # Project
    echo -e "${BOLD}${MAGENTA}📁 Project:${RESET}"
    detect_project_type
    echo -e "   Type: $_proj_display"
    
    # Detect Code Puppy project specifically
    if [[ -d "code_puppy" ]] && [[ -f "pyproject.toml" ]]; then
        echo -e "   ${GREEN}✓${RESET} This is the Code Puppy project!"
    fi
    echo ""
    
    # Agent tree
    if [[ "$SHOW_TREE" == true ]] || [[ "$VERBOSE" == true ]]; then
        build_agent_tree
    fi
    
    # Guidance stats
    echo -e "${BOLD}${GREEN}📊 Guidance Stats:${RESET}"
    echo -e "   Enabled: ${PUP_GUIDANCE_ENABLED:-${PUPPY_GUIDANCE_ENABLED:-true}}"
    echo -e "   Guidance shown: ${PUP_GUIDANCE_COUNT:-${PUPPY_GUIDANCE_COUNT:-0}}"
    echo ""
    
    # Suggested next actions
    echo -e "${BOLD}${BLUE}🎯 Suggested Actions:${RESET}"
    echo -e "   • Continue with current implementation"
    echo -e "   • Run tests: ${GRAY}pytest code_puppy/plugins/proactive_guidance/${RESET}"
    echo -e "   • Check progress: ${GRAY}git log --oneline -5${RESET}"
    echo -e "   • View files: ${GRAY}ls -la code_puppy/plugins/proactive_guidance/${RESET}"
    echo ""
    
    echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
    echo -e "${GRAY}Run with --verbose for more details, --json for parsing${RESET}"
}

# Main
main() {
    case "$OUTPUT_FORMAT" in
        json)
            output_json
            ;;
        text)
            output_text
            ;;
    esac
}

main "$@"
