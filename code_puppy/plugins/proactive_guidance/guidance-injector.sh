#!/bin/bash
# guidance-injector.sh - Generate contextual follow-up suggestions
# Usage: guidance-injector.sh <tool_name> [args...]
#
# This script generates next-step guidance based on the tool that was executed.
# It's designed to be called by the proactive guidance plugin or used standalone.
#
# Examples:
#   guidance-injector.sh write_file src/main.py "some content"
#   guidance-injector.sh run_shell_command "pytest tests/"
#   guidance-injector.sh invoke_agent turbo_executor

set -euo pipefail

# Colors for output (optional, disabled if NO_COLOR is set)
if [[ -z "${NO_COLOR:-}" ]]; then
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    BOLD=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

# Get verbosity level from env or default to normal
VERBOSITY="${GUIDANCE_VERBOSITY:-normal}"

# Show help if requested
if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    echo "Usage: guidance-injector.sh <tool_name> [tool_result] [options]"
    echo ""
    echo "Injects follow-up guidance after tool execution."
    echo ""
    echo "Tools: write_file, replace_in_file, run_shell_command, invoke_agent"
    echo ""
    echo "Options:"
    echo "  --verbosity <level>  Set verbosity (minimal|normal|verbose)"
    echo "  -h, --help           Show this help message"
    exit 0
fi

# Show header
echo -e "${BOLD}🐾 Proactive Guidance${RESET}"
echo ""

# Check if we have enough arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <tool_name> [args...]"
    echo ""
    echo "Tools supported:"
    echo "  write_file <path> [content_preview]"
    echo "  replace_in_file <path>"
    echo "  run_shell_command <command> [exit_code]"
    echo "  invoke_agent <agent_name>"
    echo ""
    echo "Environment variables:"
    echo "  GUIDANCE_VERBOSITY=minimal|normal|verbose"
    echo "  NO_COLOR=1 (disable colors)"
    exit 1
fi

TOOL_NAME="$1"
shift

case "$TOOL_NAME" in
    write_file|create_file)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $0 $TOOL_NAME <file_path> [content_preview]"
            exit 1
        fi
        
        FILE_PATH="$1"
        EXTENSION="${FILE_PATH##*.}"
        EXTENSION_LOWER=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')
        
        echo -e "${CYAN}✨ Next steps for your new file:${RESET}"
        echo ""
        
        # Language-specific suggestions
        case "$EXTENSION_LOWER" in
            py)
                echo -e "${GREEN}💡${RESET} Run tests: pytest $FILE_PATH"
                echo -e "${GREEN}🔍${RESET} Check syntax: python -m py_compile $FILE_PATH"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📝${RESET} Type check: mypy $FILE_PATH (if mypy installed)"
                ;;
            js|jsx|ts|tsx)
                echo -e "${GREEN}💡${RESET} Run tests: npm test"
                echo -e "${GREEN}🔍${RESET} Lint: npx eslint $FILE_PATH"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📝${RESET} Type check: npx tsc --noEmit"
                ;;
            rs)
                echo -e "${GREEN}💡${RESET} Run tests: cargo test"
                echo -e "${GREEN}🔍${RESET} Check: cargo check"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📝${RESET} Format: cargo fmt"
                ;;
            go)
                echo -e "${GREEN}💡${RESET} Run tests: go test ./..."
                echo -e "${GREEN}🔍${RESET} Build: go build"
                ;;
            java)
                echo -e "${GREEN}💡${RESET} Compile: javac $FILE_PATH"
                echo -e "${GREEN}🔍${RESET} Run tests: mvn test (if Maven project)"
                ;;
            sh|bash|zsh)
                echo -e "${GREEN}🔐${RESET} Check script: shellcheck $FILE_PATH (if installed)"
                echo -e "${GREEN}▶️${RESET} Make executable: chmod +x $FILE_PATH"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📜${RESET} Run: ./$FILE_PATH"
                ;;
            md|rst|txt)
                echo -e "${GREEN}📝${RESET} Preview: head -20 $FILE_PATH"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📊${RESET} Word count: wc -w $FILE_PATH"
                ;;
            json)
                echo -e "${GREEN}✅${RESET} Validate: python -c 'import json; json.load(open(\"$FILE_PATH\"))'"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}🔍${RESET} Pretty print: cat $FILE_PATH | python -m json.tool"
                ;;
            yaml|yml)
                echo -e "${GREEN}✅${RESET} Validate: python -c 'import yaml; yaml.safe_load(open(\"$FILE_PATH\"))' (if PyYAML installed)"
                ;;
            toml)
                echo -e "${GREEN}✅${RESET} Validate: python -c 'import tomllib; tomllib.load(open(\"$FILE_PATH\", \"rb\"))'"
                ;;
            html|htm)
                echo -e "${GREEN}🌐${RESET} Validate: Use W3C validator or html5validator"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}🔍${RESET} Preview: open $FILE_PATH (macOS)"
                ;;
            css)
                echo -e "${GREEN}🎨${RESET} Validate: npx stylelint $FILE_PATH"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}📦${RESET} Minify: npx cssnano $FILE_PATH"
                ;;
            *)
                echo -e "${GREEN}📂${RESET} View file: cat $FILE_PATH"
                echo -e "${GREEN}📊${RESET} File info: ls -la $FILE_PATH"
                ;;
        esac
        
        # General suggestions for all files (non-minimal verbosity)
        if [[ "$VERBOSITY" != "minimal" ]]; then
            echo ""
            echo -e "${YELLOW}📂${RESET} View file: cat $FILE_PATH"
            echo -e "${YELLOW}🔎${RESET} Search for usages: grep -r \"$(basename $FILE_PATH .${EXTENSION})\" ."
        fi
        
        # Verbose suggestions
        if [[ "$VERBOSITY" == "verbose" ]]; then
            echo ""
            echo -e "${BLUE}🧪${RESET} Create a test file for this implementation"
            echo -e "${BLUE}📊${RESET} Check git diff: git diff --stat"
        fi
        ;;
        
    replace_in_file)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $0 replace_in_file <file_path>"
            exit 1
        fi
        
        FILE_PATH="$1"
        echo -e "${CYAN}✨ File modified successfully!${RESET}"
        echo ""
        echo -e "${GREEN}📂${RESET} View changes: git diff $FILE_PATH"
        echo -e "${GREEN}🔍${RESET} Check syntax: Depends on file type"
        [[ "$VERBOSITY" != "minimal" ]] && echo -e "${YELLOW}📝${RESET} Review: cat $FILE_PATH | head -30"
        ;;
        
    run_shell_command|shell_command|shell)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $0 run_shell_command <command> [exit_code]"
            exit 1
        fi
        
        COMMAND="$1"
        EXIT_CODE="${2:-0}"
        
        if [[ "$EXIT_CODE" -eq 0 ]]; then
            echo -e "${CYAN}✅ Command completed successfully!${RESET}"
            echo ""
            
            # Context-aware suggestions based on command type
            if [[ "$COMMAND" =~ (pytest|test|npm test|cargo test|go test) ]]; then
                echo -e "${GREEN}🎯${RESET} Tests passed! Ready to commit?"
                echo -e "${GREEN}📊${RESET} Coverage: pytest --cov (if pytest-cov installed)"
                [[ "$VERBOSITY" == "verbose" ]] && echo -e "${BLUE}📝${RESET} Save coverage report: pytest --cov --cov-report=html"
                
            elif [[ "$COMMAND" =~ (git add|git commit) ]]; then
                echo -e "${GREEN}🚀${RESET} Push changes: git push origin \$(git branch --show-current)"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${YELLOW}🔄${RESET} Or create PR: gh pr create (if gh CLI installed)"
                
            elif [[ "$COMMAND" =~ (build|make|cargo build|npm run build|go build) ]]; then
                echo -e "${GREEN}🎯${RESET} Build succeeded! Run your binary or check build artifacts"
                [[ "$VERBOSITY" != "minimal" ]] && echo -e "${YELLOW}📦${RESET} Package: Check dist/ or target/ directories"
                
            elif [[ "$COMMAND" =~ (pip install|npm install|cargo add|go get) ]]; then
                echo -e "${GREEN}📦${RESET} Dependencies updated!"
                [[ "$COMMAND" =~ pip ]] && echo -e "${YELLOW}🔒${RESET} Lock: pip freeze > requirements.txt"
                [[ "$COMMAND" =~ npm ]] && echo -e "${YELLOW}🔒${RESET} Lock: npm shrinkwrap"
                [[ "$COMMAND" =~ cargo ]] && echo -e "${YELLOW}🔒${RESET} Lock: Cargo.lock updated automatically"
                
            elif [[ "$COMMAND" =~ (grep|find|rg) ]]; then
                echo -e "${GREEN}🔍${RESET} Found matches! Open interesting files to explore"
                
            elif [[ "$COMMAND" =~ (ls|tree|fd) ]]; then
                echo -e "${GREEN}📂${RESET} Explore further or run a command in those directories"
                
            elif [[ "$COMMAND" =~ (docker|podman) ]]; then
                echo -e "${GREEN}🐳${RESET} Container command executed! Check status with docker ps"
                
            elif [[ "$COMMAND" =~ (kubectl|helm) ]]; then
                echo -e "${GREEN}☸️${RESET} Kubernetes command executed! Check: kubectl get pods"
                
            else
                echo -e "${GREEN}▶️${RESET} Run similar command: Use ↑ in shell or command history"
            fi
            
            # General suggestions
            if [[ "$VERBOSITY" != "minimal" ]]; then
                echo ""
                echo -e "${YELLOW}📜${RESET} Command history: Press ↑ or run 'history | tail'"
            fi
        else
            echo -e "${CYAN}⚠️ Command failed with exit code $EXIT_CODE${RESET}"
            echo ""
            echo -e "${YELLOW}🔧 Debug options:${RESET}"
            echo "   - Check error output above"
            echo "   - Run with verbose: Add -v or --verbose flags"
            echo "   - Check environment: env | grep -i <key>"
            [[ "$VERBOSITY" != "minimal" ]] && echo "   - Try: $COMMAND 2>&1 | head -50 (to see errors)"
        fi
        ;;
        
    invoke_agent|agent|subagent)
        if [[ $# -lt 1 ]]; then
            echo "Usage: $0 invoke_agent <agent_name>"
            exit 1
        fi
        
        AGENT_NAME="$1"
        echo -e "${CYAN}🤖 Agent '$AGENT_NAME' completed!${RESET}"
        echo ""
        echo -e "${GREEN}📋${RESET} Review the agent's output above"
        [[ "$VERBOSITY" != "minimal" ]] && echo -e "${GREEN}🔄${RESET} Iterate: Make adjustments and re-invoke if needed"
        [[ "$VERBOSITY" == "verbose" ]] && echo -e "${BLUE}📝${RESET} Document learnings in code comments"
        ;;
        
    read_file|grep|list_files)
        echo -e "${CYAN}📖 Exploratory tool used${RESET}"
        echo ""
        echo -e "${GREEN}🔍${RESET} Next: Use findings to make changes or gather more info"
        echo -e "${GREEN}📝${RESET} Consider: read_file on interesting files found"
        [[ "$VERBOSITY" != "minimal" ]] && echo -e "${YELLOW}🎯${RESET} Action: Create or modify files based on what you learned"
        ;;
        
    *)
        echo -e "${YELLOW}⚠️ Unknown tool: $TOOL_NAME${RESET}"
        echo "Supported tools: write_file, replace_in_file, run_shell_command, invoke_agent"
        exit 1
        ;;
esac

echo ""
echo -e "${BOLD}💡 Tip:${RESET} Disable guidance with /guidance off or set GUIDANCE_VERBOSITY=minimal"

exit 0
