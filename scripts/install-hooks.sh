#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Code Puppy — Install Git Hooks (code_puppy-df1.1)
#
# Replaces lefthook dependency with native Git hooks.
# Run once after cloning: ./scripts/install-hooks.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$SCRIPT_DIR/git-hooks"
GIT_HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
BEADS_HOOKS_DIR="$PROJECT_ROOT/.beads/hooks"

echo "🐕 Installing Code Puppy Git hooks..."

# Create .git/hooks directory if needed
mkdir -p "$GIT_HOOKS_DIR"

# Check if beads chain hooks exist — prefer those over raw hooks
# Beads chain hooks run beads integration first, then delegate to scripts/git-hooks/
if [ -f "$BEADS_HOOKS_DIR/pre-commit" ]; then
    echo "  ℹ Beads detected — installing chain hooks (beads + native)"
    SOURCE_DIR="$BEADS_HOOKS_DIR"
else
    echo "  ℹ No beads — installing raw hooks"
    SOURCE_DIR="$HOOKS_DIR"
fi

# Install pre-commit hook
if [ -f "$SOURCE_DIR/pre-commit" ]; then
    cp "$SOURCE_DIR/pre-commit" "$GIT_HOOKS_DIR/pre-commit"
    chmod +x "$GIT_HOOKS_DIR/pre-commit"
    echo "  ✓ pre-commit"
else
    echo "  ✗ pre-commit source not found at $SOURCE_DIR/pre-commit"
fi

# Install pre-push hook
if [ -f "$SOURCE_DIR/pre-push" ]; then
    cp "$SOURCE_DIR/pre-push" "$GIT_HOOKS_DIR/pre-push"
    chmod +x "$GIT_HOOKS_DIR/pre-push"
    echo "  ✓ pre-push"
else
    echo "  ✗ pre-push source not found at $SOURCE_DIR/pre-push"
fi

echo ""
echo "✅ Git hooks installed."
echo "   To uninstall: rm .git/hooks/pre-commit .git/hooks/pre-push"
