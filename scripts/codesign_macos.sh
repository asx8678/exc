#!/usr/bin/env bash
# scripts/codesign_macos.sh — Codesign + notarize macOS Burrito binaries
#
# Signs a Burrito binary with an Apple Developer ID certificate, submits it for
# notarization via notarytool, and staples the notarization ticket.  After this
# process, users won't need to bypass Gatekeeper to run the binary.
#
# Prerequisites:
#   - macOS with Xcode Command Line Tools (codesign, notarytool, stapler)
#   - Apple Developer ID Application certificate (.p12)
#   - Apple ID + app-specific password + team ID for notarization
#
# Usage (CI — credentials via environment variables):
#   export APPLE_DEVELOPER_ID_CERT_P12_B64="<base64-encoded .p12>"
#   export APPLE_DEVELOPER_ID_CERT_PASSWORD="<p12 password>"
#   export APPLE_DEVELOPER_ID_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="you@example.com"
#   export APPLE_APP_PASSWORD="<app-specific password>"
#   export APPLE_TEAM_ID="TEAMID"
#   scripts/codesign_macos.sh burrito_out/code_puppy_control_macos_arm64
#
# Usage (local — .p12 file on disk):
#   export APPLE_DEVELOPER_ID_CERT_PATH="/path/to/cert.p12"
#   export APPLE_DEVELOPER_ID_CERT_PASSWORD="<p12 password>"
#   export APPLE_DEVELOPER_ID_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="you@example.com"
#   export APPLE_APP_PASSWORD="<app-specific password>"
#   export APPLE_TEAM_ID="TEAMID"
#   scripts/codesign_macos.sh burrito_out/code_puppy_control_macos_arm64
#
# Environment variables:
#   APPLE_DEVELOPER_ID_CERT_P64_B64   Base64-encoded PKCS12 certificate (CI mode)
#   APPLE_DEVELOPER_ID_CERT_PATH      Path to PKCS12 certificate file (local mode)
#   APPLE_DEVELOPER_ID_CERT_PASSWORD  Password for the PKCS12 certificate
#   APPLE_DEVELOPER_ID_SIGNING_IDENTITY  Signing identity (e.g. "Developer ID Application: ...")
#   APPLE_ID                          Apple ID email for notarization
#   APPLE_APP_PASSWORD                App-specific password for notarization
#   APPLE_TEAM_ID                     Apple Developer Team ID
#   CODESIGN_SKIP_NOTARIZE            Set to "true" to skip notarization (sign only)
#   CODESIGN_KEYCHAIN_PASSWORD         Override auto-generated keychain password

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[codesign]${NC} $*"; }
warn()  { echo -e "${YELLOW}[codesign]${NC} $*"; }
error() { echo -e "${RED}[codesign]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[codesign]${NC} $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────

BINARY_PATH=""
SKIP_NOTARIZE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize)
      SKIP_NOTARIZE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--skip-notarize] <path-to-macos-binary>"
      echo ""
      echo "Signs and notarizes a macOS binary with Apple Developer ID."
      echo ""
      echo "Options:"
      echo "  --skip-notarize   Sign only, skip notarization + stapling"
      echo ""
      echo "Required environment variables:"
      echo "  APPLE_DEVELOPER_ID_CERT_P12_B64 or APPLE_DEVELOPER_ID_CERT_PATH"
      echo "  APPLE_DEVELOPER_ID_CERT_PASSWORD"
      echo "  APPLE_DEVELOPER_ID_SIGNING_IDENTITY"
      echo "  APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID  (for notarization)"
      exit 0
      ;;
    *)
      BINARY_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "${BINARY_PATH}" ]]; then
  error "No binary path specified. Usage: $0 [--skip-notarize] <path-to-macos-binary>"
  exit 1
fi

if [[ ! -f "${BINARY_PATH}" ]]; then
  error "Binary not found: ${BINARY_PATH}"
  exit 1
fi

# ── Validate environment ───────────────────────────────────────────────────

step "Validating environment..."

# Certificate source: base64 (CI) or file path (local)
if [[ -n "${APPLE_DEVELOPER_ID_CERT_P12_B64:-}" ]]; then
  CERT_MODE="base64"
elif [[ -n "${APPLE_DEVELOPER_ID_CERT_PATH:-}" ]]; then
  CERT_MODE="file"
else
  error "No certificate source found. Set APPLE_DEVELOPER_ID_CERT_P12_B64 (CI) or APPLE_DEVELOPER_ID_CERT_PATH (local)."
  exit 1
fi

: "${APPLE_DEVELOPER_ID_CERT_PASSWORD:?APPLE_DEVELOPER_ID_CERT_PASSWORD is required}"
: "${APPLE_DEVELOPER_ID_SIGNING_IDENTITY:?APPLE_DEVELOPER_ID_SIGNING_IDENTITY is required}"

if [[ "${SKIP_NOTARIZE}" == "false" ]]; then
  : "${APPLE_ID:?APPLE_ID is required for notarization}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required for notarization}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"
fi

# Verify macOS platform
if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This script must run on macOS. Current OS: $(uname -s)"
  exit 1
fi

# Verify tooling
for tool in codesign security; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    error "'${tool}' not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
  fi
done

if [[ "${SKIP_NOTARIZE}" == "false" ]]; then
  if ! command -v notarytool >/dev/null 2>&1; then
    error "'notarytool' not found. Install Xcode Command Line Tools."
    exit 1
  fi
fi

info "Environment validated. Cert mode: ${CERT_MODE}"

# ── Keychain setup ─────────────────────────────────────────────────────────

# Use a temporary keychain to isolate the signing certificate from the user's
# default keychain. This is the standard pattern for CI signing.
KEYCHAIN_PATH="${TMPDIR:-/tmp}/codesign_keychain_$$.keychain-db"
KEYCHAIN_PASSWORD="${CODESIGN_KEYCHAIN_PASSWORD:-$(openssl rand -base64 24)}"

# Ensure cleanup on exit (even on error)
cleanup_keychain() {
  if [[ -f "${KEYCHAIN_PATH}" ]]; then
    step "Cleaning up temporary keychain..."
    security delete-keychain "${KEYCHAIN_PATH}" 2>/dev/null || true
  fi
  # Also clean up decoded cert if we created it
  if [[ -n "${CERT_DECODE_PATH:-}" && -f "${CERT_DECODE_PATH}" ]]; then
    rm -f "${CERT_DECODE_PATH}"
  fi
}
trap cleanup_keychain EXIT

step "Creating temporary keychain: ${KEYCHAIN_PATH}"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 900 "${KEYCHAIN_PATH}"  # Auto-lock after 15 min
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

# ── Import certificate ────────────────────────────────────────────────────

step "Importing Apple Developer ID certificate..."

if [[ "${CERT_MODE}" == "base64" ]]; then
  CERT_DECODE_PATH="${TMPDIR:-/tmp}/codesign_cert_$$.p12"
  echo "${APPLE_DEVELOPER_ID_CERT_P12_B64}" | base64 --decode > "${CERT_DECODE_PATH}"
  CERT_IMPORT_PATH="${CERT_DECODE_PATH}"
else
  CERT_IMPORT_PATH="${APPLE_DEVELOPER_ID_CERT_PATH}"
fi

security import "${CERT_IMPORT_PATH}" \
  -P "${APPLE_DEVELOPER_ID_CERT_PASSWORD}" \
  -A -t cert -f pkcs12 \
  -k "${KEYCHAIN_PATH}"

# Grant codesign access to the imported key
security set-key-partition-list \
  -S apple-tool:,apple: \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

# Add to keychain search list so codesign can find it
security list-keychain -d user -s "${KEYCHAIN_PATH}"

info "Certificate imported successfully."

# ── Codesign ───────────────────────────────────────────────────────────────

step "Codesigning binary: ${BINARY_PATH}"
step "  Identity: ${APPLE_DEVELOPER_ID_SIGNING_IDENTITY}"

codesign --sign "${APPLE_DEVELOPER_ID_SIGNING_IDENTITY}" \
  --options runtime \
  --force \
  --timestamp \
  --verbose=2 \
  "${BINARY_PATH}"

info "Codesigning complete. Verifying signature..."

codesign --verify --verbose=2 "${BINARY_PATH}"
codesign -dvv "${BINARY_PATH}" 2>&1 | head -20

info "Signature verified ✓"

# ── Notarize ───────────────────────────────────────────────────────────────

if [[ "${SKIP_NOTARIZE}" == "true" ]]; then
  warn "Skipping notarization (--skip-notarize flag)."
  warn "Binary is signed but NOT notarized — Gatekeeper will still warn."
  exit 0
fi

step "Preparing notarization submission..."

# notarytool requires a .zip, .dmg, or .pkg file — raw binaries aren't accepted.
# We use ditto to create a zip that preserves macOS metadata.
ZIP_PATH="${TMPDIR:-/tmp}/notarization_submit_$$.zip"
ditto -c -k --keepParent "${BINARY_PATH}" "${ZIP_PATH}"

step "Submitting for notarization (this may take several minutes)..."
step "  Apple ID: ${APPLE_ID}"
step "  Team ID:  ${APPLE_TEAM_ID}"

SUBMIT_OUTPUT=$(notarytool submit "${ZIP_PATH}" \
  --apple-id "${APPLE_ID}" \
  --password "${APPLE_APP_PASSWORD}" \
  --team-id "${APPLE_TEAM_ID}" \
  --wait \
  2>&1) || true

echo "${SUBMIT_OUTPUT}"

# Check notarization result
if echo "${SUBMIT_OUTPUT}" | grep -q "status: Accepted"; then
  info "Notarization successful ✓"
else
  error "Notarization FAILED. Fetching log..."
  # Attempt to fetch the log for the last submission
  notarytool log \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" \
    last 2>/dev/null || true
  rm -f "${ZIP_PATH}"
  exit 1
fi

rm -f "${ZIP_PATH}"

# ── Staple ─────────────────────────────────────────────────────────────────

step "Stapling notarization ticket to binary..."

xcrun stapler staple "${BINARY_PATH}"

step "Validating staple..."
xcrun stapler validate "${BINARY_PATH}"

info "Staple validated ✓"

# ── Final verification ────────────────────────────────────────────────────

step "Final verification..."

# spctl assesses whether the binary passes Gatekeeper checks
# --type execute for command-line executables (not .app bundles)
spctl --assess --type execute "${BINARY_PATH}" 2>&1 || {
  warn "spctl assessment returned non-zero (may be normal for CLI binaries)"
  warn "This doesn't necessarily mean the binary is invalid."
}

info "═════════════════════════════════════════════════════════"
info "macOS codesigning + notarization complete!"
info "  Binary:     ${BINARY_PATH}"
info "  Identity:   ${APPLE_DEVELOPER_ID_SIGNING_IDENTITY}"
info "  Notarized:  yes"
info "  Stapled:    yes"
info "═════════════════════════════════════════════════════════"
