#!/usr/bin/env bash
# install-git-hooks.sh — install tracked hooks into the active hooks path
#
# Finds the active hooks path (via `git rev-parse --git-path hooks`), then
# creates chaining scripts that delegate to the tracked scripts in
# scripts/git-hooks/.
#
# The chaining scripts use runtime repo-root resolution (git rev-parse)
# rather than install-time relative paths, so they work even if the
# hooks directory is not inside the repo tree.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TRACKED_DIR="$PROJECT_ROOT/scripts/git-hooks"

# --- helpers ----------------------------------------------------------------

die() {
  printf >&2 'ERROR: %s\n' "$*"
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

confirm() {
  printf '%s [y/N] ' "$*"
  read -r ans
  case "${ans:-N}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- discover hooks path ----------------------------------------------------

HOOKS_PATH="$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks 2>/dev/null)" \
  || die "not inside a git repository"

# Make the hooks path absolute
case "$HOOKS_PATH" in
  /*) ;;
  *) HOOKS_PATH="$PROJECT_ROOT/$HOOKS_PATH" ;;
esac

if [[ ! -d "$HOOKS_PATH" ]]; then
  if confirm "hooks path '$HOOKS_PATH' does not exist — create it?"; then
    mkdir -p "$HOOKS_PATH"
    info "created $HOOKS_PATH"
  else
    die "hooks path does not exist; cannot install"
  fi
fi

info "active hooks path: $HOOKS_PATH"
info "project root: $PROJECT_ROOT"
info "tracked hooks: $TRACKED_DIR"

# --- verify tracked scripts exist -------------------------------------------

for hook in pre-commit pre-push; do
  tracked="$TRACKED_DIR/$hook"
  if [[ ! -f "$tracked" ]]; then
    die "tracked script not found: $tracked"
  fi
  if [[ ! -x "$tracked" ]]; then
    info "making $tracked executable ..."
    chmod +x "$tracked"
  fi
done

# --- install chaining scripts -----------------------------------------------

install_chain_with_beads() {
  local hook="$1"
  local chaining="$HOOKS_PATH/$hook"

  if [[ -f "$chaining" ]]; then
    # If it already has the beads block + chaining, just ensure it's executable
    if grep -q 'BEGIN BEADS INTEGRATION' "$chaining" 2>/dev/null && \
       grep -q 'scripts/git-hooks' "$chaining" 2>/dev/null; then
      info "$chaining already has beads + chaining — making executable"
      chmod +x "$chaining"
      return
    fi

    # If it has beads block but no chaining, append chaining
    if grep -q 'BEGIN BEADS INTEGRATION' "$chaining" 2>/dev/null; then
      info "appending chaining to existing beads hook: $chaining"
      cat >> "$chaining" <<-CHAINEOF

# Chain to tracked script (added by scripts/install-git-hooks.sh)
_root="\$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
_script="\$_root/scripts/git-hooks/$hook"
if [ -x "\$_script" ]; then
  exec "\$_script" "\$@"
fi
CHAINEOF
      chmod +x "$chaining"
      return
    fi

    # Otherwise backup and create fresh
    info "backing up existing $chaining -> ${chaining}.bak"
    cp "$chaining" "${chaining}.bak"
  fi

  # Create fresh chaining script with runtime repo-root resolution
  cat > "$chaining" <<-CHAINEOF
#!/usr/bin/env sh
# Chaining hook installed by scripts/install-git-hooks.sh
# Last sync: $(date +%Y-%m-%d)
# Delegates to tracked script in the source tree via git rev-parse.

_root="\$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
_script="\$_root/scripts/git-hooks/$hook"
if [ -x "\$_script" ]; then
  exec "\$_script" "\$@"
fi
CHAINEOF

  chmod +x "$chaining"
  info "installed chaining hook: $chaining -> $TRACKED_DIR/$hook"
}

install_chain_with_beads "pre-commit"
install_chain_with_beads "pre-push"

# --- verify ----------------------------------------------------------------

info "verifying installation ..."
for hook in pre-commit pre-push; do
  installed="$HOOKS_PATH/$hook"
  if [[ -x "$installed" ]]; then
    info "  ✓ $installed"
  else
    die "  ✗ $installed not found or not executable"
  fi
done

info ""
info "hooks installed successfully!"
info "  hooks path: $HOOKS_PATH"
info "  tracked in: $TRACKED_DIR"
info ""
info "to verify: bash -n $TRACKED_DIR/pre-commit $TRACKED_DIR/pre-push"
