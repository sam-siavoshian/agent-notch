#!/usr/bin/env bash
# dev.sh — one-shot build + run for Agent in the Notch
# Usage:
#   ./dev.sh                                   # build + run, no demo prompt
#   ./dev.sh "open calculator and type 2+2"    # build + run with demo prompt
#   ./dev.sh --clean                           # nuke DerivedData, then build + run
#   ./dev.sh --build-only                      # build, don't launch
#   ./dev.sh --rotate-key sk-ant-...           # update keychain entry, then build + run
#   ./dev.sh --rotate-gemini-key AIza...       # update optional Gemini key, then build + run
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
DERIVED="${REPO_ROOT}/.build/DerivedData"

# ---------- args ----------
CLEAN=0
BUILD_ONLY=0
DEMO_PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
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
      sed -n '2,12p' "$0"; exit 0 ;;
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
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  | xcbeautify 2>/dev/null \
  || xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -40
BUILD_RC=${PIPESTATUS[0]}
set -e
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

echo ""
echo "Running in foreground. Ctrl-C to quit."
echo ""
echo "First-launch reminders:"
echo "  - System Settings → Privacy & Security → Accessibility → enable AgentNotch"
echo "  - System Settings → Privacy & Security → Screen Recording → enable AgentNotch"
echo "  - System Settings → Privacy & Security → Microphone → enable AgentNotch"
echo ""

exec "$BIN"
