#!/usr/bin/env bash
# dev.sh — one-shot build + run for Agent in the Notch
# Usage:
#   ./dev.sh                                   # build + run, no demo prompt
#   ./dev.sh "open calculator and type 2+2"    # build + run with demo prompt
#   ./dev.sh --clean                           # nuke DerivedData, then build + run
#   ./dev.sh --build-only                      # build, don't launch
#   ./dev.sh --reset-tcc                       # tccutil reset com.agentnotch.app, then build + run
#   ./dev.sh --show-onboarding                 # force-show the permissions onboarding window on launch
#   ./dev.sh --rotate-key sk-ant-...           # update keychain entry, then build + run
#   ./dev.sh --rotate-gemini-key AIza...       # update optional Gemini key, then build + run
#   ./dev.sh --install                         # build, copy to /Applications, launch from there
#                                              # (stable path → TCC grants survive close+reopen
#                                              #  as long as you don't rebuild)
#
# Secrets: reads ANTHROPIC_API_KEY from macOS keychain (service: AgentNotch,
# account: anthropic). Reads optional GEMINI_API_KEY from the same service
# (account: gemini). Never store keys in this file or in git.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN_SERVICE="AgentNotch"
KEYCHAIN_ACCOUNT="anthropic"
GEMINI_KEYCHAIN_ACCOUNT="gemini"
SCHEME="AgentNotch"
PROJECT="${REPO_ROOT}/AgentNotch.xcodeproj"
# Keep DerivedData outside iCloud Drive (repo lives on ~/Desktop which is synced).
# File Provider re-applies com.apple.FinderInfo to directories inside iCloud, which
# breaks codesign with "resource fork, Finder information, or similar detritus not allowed".
DERIVED="${HOME}/Library/Caches/AgentNotch/DerivedData"

# ---------- args ----------
CLEAN=0
BUILD_ONLY=0
RESET_TCC=0
SHOW_ONBOARDING=0
INSTALL=0
DEMO_PROMPT=""
INSTALL_PATH="/Applications/AgentNotch.app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --reset-tcc) RESET_TCC=1; shift ;;
    --show-onboarding) SHOW_ONBOARDING=1; shift ;;
    --install) INSTALL=1; shift ;;
    --rotate-key)
      shift
      if [[ -z "${1:-}" ]]; then echo "ERROR: --rotate-key needs the key as next arg"; exit 1; fi
      echo "→ Updating keychain entry for ${KEYCHAIN_SERVICE}/${KEYCHAIN_ACCOUNT}"
      security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" \
        -w "$1" \
        -U >/dev/null
      shift
      ;;
    --rotate-gemini-key)
      shift
      if [[ -z "${1:-}" ]]; then echo "ERROR: --rotate-gemini-key needs the key as next arg"; exit 1; fi
      echo "→ Updating keychain entry for ${KEYCHAIN_SERVICE}/${GEMINI_KEYCHAIN_ACCOUNT}"
      security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$GEMINI_KEYCHAIN_ACCOUNT" \
        -w "$1" \
        -U >/dev/null
      shift
      ;;
    -h|--help)
      sed -n '2,13p' "$0"; exit 0 ;;
    *)
      if [[ -z "$DEMO_PROMPT" ]]; then DEMO_PROMPT="$1"; shift
      else echo "ERROR: unexpected arg '$1'"; exit 1
      fi
      ;;
  esac
done

# ---------- secret ----------
echo "→ Fetching ANTHROPIC_API_KEY from keychain"
if ! ANTHROPIC_API_KEY="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)"; then
  echo "ERROR: no keychain entry for ${KEYCHAIN_SERVICE}/${KEYCHAIN_ACCOUNT}."
  echo "       Run:  ./dev.sh --rotate-key sk-ant-..."
  exit 1
fi
export ANTHROPIC_API_KEY

echo "→ Fetching optional GEMINI_API_KEY from keychain"
if GEMINI_API_KEY="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$GEMINI_KEYCHAIN_ACCOUNT" -w 2>/dev/null)"; then
  export GEMINI_API_KEY
  echo "→ Gemini context observation enabled"
else
  echo "→ Gemini key not configured; context observation will run OCR-only"
fi

# Recommended native screenshot-analysis baseline. The AGENTNOTCH_* names take
# precedence over generic GEMINI_* vars so sandbox experiments cannot
# accidentally change the macOS app's production context pipeline.
export AGENTNOTCH_GEMINI_MODEL="${AGENTNOTCH_GEMINI_MODEL:-gemini-3.1-flash-lite}"
export AGENTNOTCH_GEMINI_MEDIA_RESOLUTION="${AGENTNOTCH_GEMINI_MEDIA_RESOLUTION:-MEDIA_RESOLUTION_HIGH}"
export AGENTNOTCH_GEMINI_THINKING_LEVEL="${AGENTNOTCH_GEMINI_THINKING_LEVEL:-minimal}"
echo "→ Gemini config: ${AGENTNOTCH_GEMINI_MODEL}, ${AGENTNOTCH_GEMINI_MEDIA_RESOLUTION}, thinking=${AGENTNOTCH_GEMINI_THINKING_LEVEL}"

# ---------- signing guard ----------
# Without a stable Apple Development cert, every build is signed ad-hoc and
# TCC drops Accessibility / Screen Recording / Mic grants on each rebuild.
# scripts/setup-signing.sh writes a populated Local.xcconfig and re-runs
# xcodegen. We invoke it when Local.xcconfig is missing or still has the
# template placeholder. If this machine has no Apple Development cert, fall
# back to local ad-hoc signing so the build still runs.
SIGNING_ARGS=()
NEEDS_SIGNING_SETUP=0
if ! grep -qE '^DEVELOPMENT_TEAM = [A-Z0-9]+' "${REPO_ROOT}/Local.xcconfig" 2>/dev/null; then
  NEEDS_SIGNING_SETUP=1
elif grep -qE '^DEVELOPMENT_TEAM = TEAMID12$' "${REPO_ROOT}/Local.xcconfig" 2>/dev/null; then
  NEEDS_SIGNING_SETUP=1
fi

if [[ $NEEDS_SIGNING_SETUP -eq 1 ]]; then
  echo "→ Local.xcconfig missing a real DEVELOPMENT_TEAM; running scripts/setup-signing.sh"
  if ! "${REPO_ROOT}/scripts/setup-signing.sh"; then
    echo "→ No stable Apple Development signing available; falling back to local ad-hoc signing"
    echo "  Note: TCC permissions may need to be re-granted after rebuilds."
    SIGNING_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual)
  fi
fi

# ---------- tcc reset (opt-in) ----------
if [[ $RESET_TCC -eq 1 ]]; then
  echo "→ tccutil reset All com.agentnotch.app"
  tccutil reset All com.agentnotch.app 2>/dev/null || true
fi

# ---------- xcodegen ----------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen not found. Install with 'brew install xcodegen'."
  exit 1
fi
echo "→ xcodegen generate"
(cd "$REPO_ROOT" && xcodegen generate --quiet)

# ---------- clean ----------
if [[ $CLEAN -eq 1 ]]; then
  echo "→ Nuking DerivedData"
  rm -rf "$DERIVED"
fi

# ---------- build ----------
echo "→ xcodebuild ($SCHEME)"
mkdir -p "$DERIVED"
set +e
if [[ ${#SIGNING_ARGS[@]} -gt 0 ]]; then
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    "${SIGNING_ARGS[@]}" \
    | xcbeautify 2>/dev/null
  BUILD_RC=${PIPESTATUS[0]}
  if [[ $BUILD_RC -ne 0 ]]; then
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED" \
      "${SIGNING_ARGS[@]}" \
      2>&1 | tail -40
    BUILD_RC=${PIPESTATUS[0]}
  fi
else
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    | xcbeautify 2>/dev/null
  BUILD_RC=${PIPESTATUS[0]}
  if [[ $BUILD_RC -ne 0 ]]; then
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED" \
      2>&1 | tail -40
    BUILD_RC=${PIPESTATUS[0]}
  fi
fi
set -e

# Codesign sometimes rejects the bundle because CopySwiftLibs copies in
# Swift runtime dylibs with extended attributes ("resource fork ... or
# similar detritus not allowed"). Strip them and retry the build — the
# incremental pass skips CopySwiftLibs so xattrs stay clean through sign.
APP_PATH_RETRY="${DERIVED}/Build/Products/Debug/${SCHEME}.app"
if [[ $BUILD_RC -ne 0 && -d "$APP_PATH_RETRY" ]]; then
  echo "→ codesign failed — stripping xattrs and retrying"
  /usr/bin/xattr -cr "$APP_PATH_RETRY" 2>/dev/null || true
  set +e
  if [[ ${#SIGNING_ARGS[@]} -gt 0 ]]; then
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED" \
      "${SIGNING_ARGS[@]}" \
      2>&1 | tail -20
    BUILD_RC=${PIPESTATUS[0]}
  else
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED" \
      2>&1 | tail -20
    BUILD_RC=${PIPESTATUS[0]}
  fi
  set -e
fi

if [[ $BUILD_RC -ne 0 ]]; then
  echo "ERROR: build failed (rc=$BUILD_RC)"
  exit $BUILD_RC
fi

APP_PATH="${DERIVED}/Build/Products/Debug/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: built app not found at $APP_PATH"
  exit 1
fi
echo "→ Built: $APP_PATH"

if [[ $BUILD_ONLY -eq 1 ]]; then
  exit 0
fi

# ---------- kill prior instance ----------
PRIOR="$(pgrep -x "$SCHEME" || true)"
if [[ -n "$PRIOR" ]]; then
  echo "→ Killing prior $SCHEME (pid $PRIOR)"
  kill "$PRIOR" 2>/dev/null || true
  sleep 0.4
fi

# ---------- install (opt-in) ----------
# Copy built app to a stable path under /Applications. TCC grants are bound
# to (signature, bundle path). With Apple Development certs the cdhash
# changes on every rebuild, so grants still drop after a rebuild — but
# subsequent close+reopen cycles WITHOUT a rebuild keep grants intact when
# launching from the same path. Run dev.sh --install once per code change;
# after that just `open /Applications/AgentNotch.app` to relaunch without
# losing permissions.
if [[ $INSTALL -eq 1 ]]; then
  echo "→ Installing to $INSTALL_PATH"
  if [[ -d "$INSTALL_PATH" ]]; then
    rm -rf "$INSTALL_PATH"
  fi
  /bin/cp -R "$APP_PATH" "$INSTALL_PATH"
  /usr/bin/xattr -cr "$INSTALL_PATH" 2>/dev/null || true
  APP_PATH="$INSTALL_PATH"
  echo "→ Installed: $APP_PATH"
fi

# ---------- launch ----------
# Direct exec (not `open`) so env vars propagate to the app process.
# `open` hands off to launchd, which strips the calling shell's environment.
BIN="${APP_PATH}/Contents/MacOS/${SCHEME}"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: binary not executable at $BIN"
  exit 1
fi

echo "→ Launching $SCHEME"
if [[ -n "$DEMO_PROMPT" ]]; then
  echo "  DEMO PROMPT: \"$DEMO_PROMPT\""
  export ANTHROPIC_NOTCH_DEMO_PROMPT="$DEMO_PROMPT"
fi
if [[ $SHOW_ONBOARDING -eq 1 ]]; then
  echo "  FORCING onboarding window"
  export AGENTNOTCH_FORCE_ONBOARDING=1
fi

echo ""
echo "Running in foreground. Ctrl-C to quit."
echo ""
echo "First-launch reminders:"
echo "  - System Settings → Privacy & Security → Accessibility → enable AgentNotch"
echo "  - System Settings → Privacy & Security → Screen Recording → enable AgentNotch"
echo "  - System Settings → Privacy & Security → Microphone → enable AgentNotch"
echo ""

exec "$BIN"
