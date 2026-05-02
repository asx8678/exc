#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Code Puppy — Install Git Hooks (code_puppy-df1.1)
#
# Replaces lefthook dependency with native Git hooks.
# Run once after cloning: ./scripts/install-hooks.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"
GIT_HOOKS_DIR="$(git rev-parse --git-dir)/hooks"

echo "🐕 Installing Code Puppy Git hooks..."

# Create .git/hooks directory if needed
mkdir -p "$GIT_HOOKS_DIR"

# Install pre-commit hook
if [ -f "$HOOKS_DIR/pre-commit" ]; then
    cp "$HOOKS_DIR/pre-commit" "$GIT_HOOKS_DIR/pre-commit"
    chmod +x "$GIT_HOOKS_DIR/pre-commit"
    echo "  ✓ pre-commit"
else
    echo "  ✗ pre-commit source not found at $HOOKS_DIR/pre-commit"
fi

# Install pre-push hook
if [ -f "$HOOKS_DIR/pre-push" ]; then
    cp "$HOOKS_DIR/pre-push" "$GIT_HOOKS_DIR/pre-push"
    chmod +x "$GIT_HOOKS_DIR/pre-push"
    echo "  ✓ pre-push"
else
    echo "  ✗ pre-push source not found at $HOOKS_DIR/pre-push"
fi

echo ""
echo "✅ Git hooks installed. You can remove lefthook.yml now."
echo "   To uninstall: rm .git/hooks/pre-commit .git/hooks/pre-push"
